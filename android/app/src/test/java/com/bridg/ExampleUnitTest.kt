package com.bridg

import com.bridg.notify.BridgNotificationListenerService
import com.bridg.notify.BridgNotificationListenerService.Seen
import com.bridg.pairing.SessionKdf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationDedupTest {
    private fun forward(prev: Seen?, now: Long, sig: Int) =
        BridgNotificationListenerService.shouldForward(prev, now, sig)

    @Test fun firstPostAlwaysForwards() =
        assertTrue(forward(null, 1_000, 42))

    @Test fun rapidUpdateIsDropped() =
        assertFalse(forward(Seen(at = 1_000, sig = 1), now = 1_300, sig = 2))

    @Test fun identicalRepostWithinAMinuteIsDropped() =
        assertFalse(forward(Seen(at = 1_000, sig = 7), now = 31_000, sig = 7))

    @Test fun changedContentAfterDebounceForwards() =
        assertTrue(forward(Seen(at = 1_000, sig = 7), now = 31_000, sig = 8))

    @Test fun sameContentAfterAMinuteForwardsAgain() =
        assertTrue(forward(Seen(at = 1_000, sig = 7), now = 90_000, sig = 7))
}

class SessionKdfTest {

    /**
     * The same vector the Mac's BridgTests.testHKDFMatchesTheVectorAndroidDerives
     * asserts. If either side's derivation drifts, one of the two tests fails
     * here instead of showing up as a silent "decryption failed" on the wire.
     */
    @Test
    fun derivesTheSameSessionKeyAsTheMac() {
        val ikm = ByteArray(32) { it.toByte() }
        val key = SessionKdf.deriveSessionKey(ikm)

        assertEquals(
            "7e6f4ddb23319902fb5c5f3a72ec81ac8a9ddf4847463d093ff44fa72da1b3e3",
            key.joinToString("") { "%02x".format(it) }
        )
    }

    /** RFC 5869 test case 1, so the HKDF itself is pinned to the spec. */
    @Test
    fun matchesRfc5869TestCase1() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = ByteArray(13) { it.toByte() }
        val info = ByteArray(10) { (0xf0 + it).toByte() }

        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a" +
                "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                "34007208d5b887185865",
            SessionKdf.hkdfSha256(ikm, salt, info, 42).joinToString("") { "%02x".format(it) }
        )
    }
}
