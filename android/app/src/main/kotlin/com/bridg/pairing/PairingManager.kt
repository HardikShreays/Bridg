package com.bridg.pairing

import android.util.Log
import com.bridg.proto.PairRequest
import com.bridg.proto.PairResponse
import com.bridg.proto.PairResume
import com.google.protobuf.ByteString
import java.util.Base64
import java.util.UUID

/**
 * The pairing flow. The Mac shows a QR code containing its public key and a
 * one-time token; the phone scans it, dials in, and echoes the token back.
 *
 * Authentication comes from the QR being an out-of-band channel: the token
 * proves to the Mac that we saw its screen, and comparing the responder's key
 * against the scanned one proves to us we are talking to that same Mac.
 */
class PairingManager(
    private val keyManager: KeyManager
) {

    fun generatePairingToken(): String {
        val tokenBytes = ByteArray(16)
        java.security.SecureRandom().nextBytes(tokenBytes)
        return Base64.getEncoder().encodeToString(tokenBytes)
    }

    fun createPairRequest(pairingToken: String): PairRequest =
        PairRequest.newBuilder()
            .setSenderPubkey(ByteString.copyFrom(keyManager.getOrCreatePublicKey()))
            .setDeviceName(keyManager.getDeviceName())
            .setPairingToken(pairingToken)
            .build()

    /** Sent on reconnect so the Mac can look up the session key without a re-scan. */
    fun createPairResume(): PairResume =
        PairResume.newBuilder()
            .setDevicePubkeyHash(ByteString.copyFrom(keyManager.getPublicKeyHash()))
            .setTimestamp(System.currentTimeMillis())
            .build()

    /**
     * Check the Mac's PairResponse against the key we scanned out of the QR code.
     *
     * The previous version verified an Ed25519 signature made with an X25519
     * secret key — libsodium signing keys are 64 bytes and these are 32, so that
     * check could never pass. The scanned-key comparison below is the assurance
     * that actually holds.
     */
    fun verifyPairResponse(response: PairResponse, scannedPublicKey: ByteArray): ByteArray? {
        if (!response.accepted) {
            Log.w(TAG, "Pairing rejected by peer")
            return null
        }

        val peerPublicKey = response.responderPubkey.toByteArray()
        if (!peerPublicKey.contentEquals(scannedPublicKey)) {
            Log.w(TAG, "Responder key does not match the scanned QR code — possible MITM")
            return null
        }
        return peerPublicKey
    }

    fun completePairing(peerPublicKey: ByteArray, deviceName: String): String {
        val deviceId = UUID.randomUUID().toString()
        keyManager.savePairedDevice(deviceId, peerPublicKey, deviceName)
        Log.i(TAG, "Paired with device: $deviceName ($deviceId)")
        return deviceId
    }

    fun parseQrContent(content: String): QRData? {
        if (!content.startsWith(QR_CONTENT_PREFIX)) return null
        // limit=4: the device name is last and may itself contain a colon.
        val parts = content.removePrefix(QR_CONTENT_PREFIX).split(QR_SEPARATOR, limit = 4)
        if (parts.size != 4) return null

        return try {
            QRData(
                publicKey = Base64.getDecoder().decode(parts[0]),
                token = parts[1],
                host = parts[2],
                deviceName = parts[3]
            )
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Malformed QR payload: ${e.message}")
            null
        }
    }

    data class QRData(
        val publicKey: ByteArray,
        val token: String,
        /** The Mac's LAN address, so pairing works where mDNS cannot reach. */
        val host: String,
        val deviceName: String
    )

    companion object {
        private const val TAG = "PairingManager"
        private const val QR_CONTENT_PREFIX = "bridg://pair/"
        private const val QR_SEPARATOR = ":"
    }
}
