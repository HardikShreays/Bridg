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
        val written = if (messageLength[0] > 0) messageLength[0].toInt() else plaintext.size
        return plaintext.copyOf(written)
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
