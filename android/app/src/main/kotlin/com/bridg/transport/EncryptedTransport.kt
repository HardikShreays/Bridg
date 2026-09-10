package com.bridg.transport

import android.util.Log
import com.goterl.lazysodium.LazySodiumAndroid
import com.goterl.lazysodium.SodiumAndroid
import com.goterl.lazysodium.interfaces.AEAD
import java.util.concurrent.atomic.AtomicLong

/**
 * ChaCha20-Poly1305 (IETF) AEAD for the transport layer.
 * Byte-compatible with CryptoKit's `ChaChaPoly` on the Mac side.
 */
class EncryptedTransport(
    sharedKey: ByteArray,
    /**
     * Both directions share one key, so the two sides must draw from disjoint
     * nonce spaces — a repeated (key, nonce) pair breaks ChaCha20-Poly1305
     * badly. The first nonce byte tags the direction. The Mac sends 0x00.
     */
    private val sendDirection: Byte = DIRECTION_PHONE_TO_MAC
) {
    private val sodium = LazySodiumAndroid(SodiumAndroid())
    private val nonceCounter = AtomicLong(0)

    /** Highest counter accepted from the peer, so a replayed frame is refused. */
    private var lastPeerCounter = 0L

    /** The peer sends on the direction we do not. */
    private val receiveDirection: Byte =
        if (sendDirection == DIRECTION_MAC_TO_PHONE) DIRECTION_PHONE_TO_MAC else DIRECTION_MAC_TO_PHONE

    private val key: ByteArray = sharedKey.copyOf(AEAD.CHACHA20POLY1305_IETF_KEYBYTES)

    fun encrypt(plaintext: ByteArray): ByteArray? {
        val nonce = nextNonce()
        val ciphertext = ByteArray(plaintext.size + AEAD.CHACHA20POLY1305_IETF_ABYTES)
        val macLength = longArrayOf(0)

        val success = sodium.cryptoAeadChaCha20Poly1305IetfEncrypt(
            ciphertext, macLength, plaintext, plaintext.size.toLong(),
            null, 0, null, nonce, key
        )

        if (!success) {
            Log.e(TAG, "Encryption failed")
            return null
        }
        // macLength is the total ciphertext+tag length; guard against a 0 report.
        val written = if (macLength[0] > 0) macLength[0].toInt() else ciphertext.size
        return nonce + ciphertext.copyOf(written)
    }

    fun decrypt(encrypted: ByteArray): ByteArray? {
        if (encrypted.size < NONCE_SIZE + AEAD.CHACHA20POLY1305_IETF_ABYTES) {
            Log.e(TAG, "Encrypted message too short")
            return null
        }

        val nonce = encrypted.copyOfRange(0, NONCE_SIZE)
        val counter = checkNonce(nonce) ?: return null

        val ciphertext = encrypted.copyOfRange(NONCE_SIZE, encrypted.size)
        val plaintext = ByteArray(ciphertext.size - AEAD.CHACHA20POLY1305_IETF_ABYTES)
        val messageLength = longArrayOf(0)

        val success = sodium.cryptoAeadChaCha20Poly1305IetfDecrypt(
            plaintext, messageLength, null, ciphertext, ciphertext.size.toLong(),
            null, 0, nonce, key
        )

        if (!success) {
            Log.e(TAG, "Decryption failed — wrong key or tampered frame")
            return null
        }
        // Only now, with the tag verified. Advancing on an unauthenticated
        // nonce would let anyone who can write to the socket send one forged
        // frame with a huge counter and wedge every real frame after it.
        commit(counter)

        val written = if (messageLength[0] > 0) messageLength[0].toInt() else plaintext.size
        return plaintext.copyOf(written)
    }

    /**
     * Reject anything the peer cannot legitimately have just sent.
     *
     * Both directions share one key, so a frame of ours reflected back at us
     * decrypts perfectly — the direction byte is what tells the two apart. And
     * because the transport rides on ordered TCP, a counter that does not
     * strictly increase is a replayed or reordered frame, never a normal one.
     *
     * This is defence in depth: the per-connection salt already means a frame
     * captured from an earlier session cannot open under this session's key.
     */
    private fun checkNonce(nonce: ByteArray): Long? {
        if (nonce[0] != receiveDirection) {
            Log.e(TAG, "Frame carries our own direction byte — reflected")
            return null
        }
        val counter = java.nio.ByteBuffer.wrap(nonce, 4, 8).long
        synchronized(this) {
            if (counter <= lastPeerCounter) {
                Log.e(TAG, "Nonce counter did not advance ($counter <= $lastPeerCounter) — replayed")
                return null
            }
        }
        return counter
    }

    private fun commit(counter: Long) {
        synchronized(this) { lastPeerCounter = maxOf(lastPeerCounter, counter) }
    }

    /** Layout must match the Mac: [0] direction, [1..3] zero, [4..11] big-endian counter. */
    private fun nextNonce(): ByteArray {
        val counter = nonceCounter.incrementAndGet()
        val nonce = ByteArray(NONCE_SIZE)
        nonce[0] = sendDirection
        java.nio.ByteBuffer.wrap(nonce, 4, 8).putLong(counter)
        return nonce
    }

    companion object {
        private const val TAG = "EncryptedTransport"
        private const val NONCE_SIZE = 12
        const val DIRECTION_MAC_TO_PHONE: Byte = 0x00
        const val DIRECTION_PHONE_TO_MAC: Byte = 0x01
    }
}
