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

    fun deriveSessionKey(rawSharedSecret: ByteArray): ByteArray =
        hkdfSha256(rawSharedSecret, SALT, ByteArray(0), 32)

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
