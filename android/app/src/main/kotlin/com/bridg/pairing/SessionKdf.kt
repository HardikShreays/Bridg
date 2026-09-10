package com.bridg.pairing

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Turns a raw X25519 shared secret into the 32-byte session key.
 *
 * Kept free of Android dependencies so it can be unit-tested on the JVM against
 * the same vector the Mac's SharedSecretKDF is pinned to. The two sides
 * disagreeing here is invisible until every encrypted frame fails to open.
 */
object SessionKdf {

    /** Must match the salt the Mac passes to HKDF. */
    private val SALT = "bridg-session".toByteArray()

    /** Bytes each side contributes per connection. Not secret, only fresh. */
    const val SALT_LENGTH = 16

    /** A fresh per-connection salt. */
    fun randomSalt(): ByteArray =
        ByteArray(SALT_LENGTH).also { java.security.SecureRandom().nextBytes(it) }

    /**
     * HKDF `info` for one connection, in a fixed order both sides agree on.
     *
     * The phone always dials in, so it is always the initiator; the Mac always
     * answers. Concatenating in the other order would give the two ends
     * different keys.
     */
    fun connectionInfo(initiatorSalt: ByteArray, responderSalt: ByteArray): ByteArray =
        initiatorSalt + responderSalt

    /**
     * Derive the session key for one connection.
     *
     * [info] MUST carry both sides' fresh salts. Both identity keys are
     * long-term, so [rawSharedSecret] is identical on every connection; it is
     * only the salts that stop the key — and with it the whole (key, nonce)
     * sequence, since the nonce counter restarts at zero each time — from
     * repeating. A repeated (key, nonce) under ChaCha20-Poly1305 leaks the XOR
     * of two plaintexts and the Poly1305 authentication key.
     */
    fun deriveSessionKey(rawSharedSecret: ByteArray, info: ByteArray): ByteArray {
        require(info.isNotEmpty()) { "session key derived without per-connection salts" }
        return hkdfSha256(rawSharedSecret, SALT, info, 32)
    }

    /** RFC 5869 HKDF-SHA256: extract, then expand. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmacSha256(salt, ikm)

        val output = ByteArray(length)
        var previousBlock = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            val block = hmacSha256(prk, previousBlock + info + byteArrayOf(counter.toByte()))
            val take = minOf(block.size, length - written)
            block.copyInto(output, written, 0, take)
            written += take
            previousBlock = block
            counter++
        }
        return output
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        // An all-zero salt is a valid HMAC key, but SecretKeySpec rejects an empty one.
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}
