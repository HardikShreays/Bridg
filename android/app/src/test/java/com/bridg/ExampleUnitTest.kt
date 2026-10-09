package com.bridg

import com.bridg.notify.BridgNotificationListenerService
import com.bridg.notify.BridgNotificationListenerService.Seen
import com.bridg.pairing.SessionKdf
import com.bridg.proto.DeviceStatus
import com.bridg.proto.Envelope
import com.bridg.proto.PairResume
import com.bridg.transport.FrameCodec
import java.io.DataInputStream
import com.bridg.remote.RemoteActionHandler
import com.bridg.status.BatteryMonitor
import com.bridg.transport.BridgSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    private val ikm = ByteArray(32) { it.toByte() }
    private val initiatorSalt = ByteArray(16) { (0xa0 + it).toByte() }
    private val responderSalt = ByteArray(16) { (0xb0 + it).toByte() }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    /**
     * The same vector the Mac's BridgTests.testHKDFMatchesTheVectorAndroidDerives
     * asserts. If either side's derivation drifts, one of the two tests fails
     * here instead of showing up as a silent "decryption failed" on the wire.
     */
    @Test
    fun derivesTheSameSessionKeyAsTheMac() {
        val key = SessionKdf.deriveSessionKey(
            ikm,
            SessionKdf.connectionInfo(initiatorSalt, responderSalt)
        )

        assertEquals(
            "9bcc4b236bef52d412a912466352d92779a5e878648cf7f60f9c12f4c26e6b63",
            key.hex()
        )
    }

    /**
     * We are always the initiator — the phone dials in — so our salt comes
     * first. Swapping the order gives a different key, and the two sides
     * disagreeing is invisible until every frame fails to open.
     */
    @Test
    fun saltOrderIsPartOfTheContract() {
        assertNotEquals(
            SessionKdf.deriveSessionKey(ikm, SessionKdf.connectionInfo(initiatorSalt, responderSalt)).hex(),
            SessionKdf.deriveSessionKey(ikm, SessionKdf.connectionInfo(responderSalt, initiatorSalt)).hex()
        )
    }

    /**
     * The reason the salts exist at all.
     *
     * Both identity keys are long-term, so the raw ECDH secret is the same on
     * every connection, and the nonce counter restarts at zero each time. If
     * the session key did not change too, connection #2 would encrypt with the
     * exact (key, nonce) pairs connection #1 already used — which leaks the XOR
     * of the two plaintexts and the Poly1305 authentication key.
     */
    @Test
    fun sessionKeyDiffersPerConnectionForOneIdentityPair() {
        val keys = (1..50).map {
            SessionKdf.deriveSessionKey(
                ikm,
                SessionKdf.connectionInfo(SessionKdf.randomSalt(), SessionKdf.randomSalt())
            ).hex()
        }.toSet()

        assertEquals(50, keys.size)
        assertEquals(SessionKdf.SALT_LENGTH, SessionKdf.randomSalt().size)
    }

    /** Deriving without the per-connection salts is the bug, so it must not compile away silently. */
    @Test(expected = IllegalArgumentException::class)
    fun refusesToDeriveWithoutSalts() {
        SessionKdf.deriveSessionKey(ikm, ByteArray(0))
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


class BatteryForwardingTest {

    private fun status(percent: Int, charging: Boolean = false, low: Boolean = false) =
        DeviceStatus.newBuilder()
            .setBatteryPercent(percent)
            .setCharging(charging)
            .setBatteryLow(low)
            .build()

    @Test fun firstReadingAlwaysForwards() =
        assertTrue(BatteryMonitor.shouldForward(null, status(50)))

    /**
     * ACTION_BATTERY_CHANGED fires on voltage and temperature ticks, many times
     * a minute, with the percentage unmoved. Forwarding those is pure wire churn.
     */
    @Test fun unchangedReadingIsDropped() =
        assertFalse(BatteryMonitor.shouldForward(status(50), status(50)))

    @Test fun percentChangeForwards() =
        assertTrue(BatteryMonitor.shouldForward(status(50), status(49)))

    @Test fun pluggingInForwardsEvenAtTheSamePercent() =
        assertTrue(BatteryMonitor.shouldForward(status(50), status(50, charging = true)))

    @Test fun crossingTheLowThresholdForwards() =
        assertTrue(BatteryMonitor.shouldForward(status(15), status(15, low = true)))
}

class RemoteUrlTest {

    /**
     * The Mac hands us a string and we hand it to the system to launch, so this
     * is a trust boundary. The Mac's AppState.isSendableURL must agree — its own
     * test pins the same cases.
     */
    @Test
    fun acceptsOnlyHttpAndHttps() {
        assertTrue(RemoteActionHandler.isAllowedUrl("https://example.com"))
        assertTrue(RemoteActionHandler.isAllowedUrl("http://example.com/a?b=c#d"))
        assertTrue(RemoteActionHandler.isAllowedUrl("  https://example.com  "))
        assertTrue(RemoteActionHandler.isAllowedUrl("HTTPS://example.com"))
    }

    @Test
    fun rejectsEverythingElse() {
        // intent:// can start arbitrary components; file:// exposes storage.
        assertFalse(RemoteActionHandler.isAllowedUrl("intent://scan/#Intent;scheme=zxing;end"))
        assertFalse(RemoteActionHandler.isAllowedUrl("file:///data/data/com.bridg/databases"))
        assertFalse(RemoteActionHandler.isAllowedUrl("javascript:alert(1)"))
        assertFalse(RemoteActionHandler.isAllowedUrl("tel:+15551234"))
        assertFalse(RemoteActionHandler.isAllowedUrl("example.com"))
        assertFalse(RemoteActionHandler.isAllowedUrl("https://"))
        assertFalse(RemoteActionHandler.isAllowedUrl(""))
        assertFalse(RemoteActionHandler.isAllowedUrl("not a url at all"))
    }
}

class BridgSocketTest {

    /**
     * Known-host dialling and Bonjour discovery race to connect. When both got
     * through, the second socket overwrote the first one's streams and the Mac
     * cancelled the first mid-handshake, so the link never authenticated and
     * reconnected forever. Exactly one attempt may win.
     */
    @Test
    fun concurrentConnectsOpenOneSocket() {
        ServerSocket(0).use { server ->
            val accepted = AtomicInteger()
            Thread {
                runCatching { while (true) { server.accept(); accepted.incrementAndGet() } }
            }.apply { isDaemon = true; start() }

            val socket = BridgSocket()
            val results = runBlocking {
                (1..2).map { async(Dispatchers.IO) { socket.connect("127.0.0.1", server.localPort) } }.awaitAll()
            }
            Thread.sleep(200)

            assertEquals(listOf(false, true), results.sorted())
            assertEquals(1, accepted.get())
            socket.disconnect()
        }
    }

    /**
     * Before the Mac's half of the salt arrives there is no session key, so an
     * update queued at connect time went out in plaintext and the Mac, already
     * expecting sealed frames, dropped the link. Only the handshake may precede
     * encryption.
     */
    @Test
    fun onlyTheHandshakeGoesOutBeforeEncryption() {
        ServerSocket(0).use { server ->
            val socket = BridgSocket()
            runBlocking { socket.connect("127.0.0.1", server.localPort) }
            server.accept().use { peer ->
                peer.soTimeout = 2_000
                socket.send(
                    Envelope.newBuilder()
                        .setDeviceStatus(DeviceStatus.newBuilder().setBatteryPercent(50).build())
                        .build()
                )
                socket.send(Envelope.newBuilder().setPairResume(PairResume.getDefaultInstance()).build())

                val first = FrameCodec.readFrame(DataInputStream(peer.getInputStream()))
                assertEquals(Envelope.PayloadCase.PAIR_RESUME, Envelope.parseFrom(first!!).payloadCase)
            }
            socket.disconnect()
        }
    }

    /**
     * The phone dials anything advertising _bridg._tcp. A rogue host on the
     * Wi-Fi could then send plaintext InputEvents (taps via the accessibility
     * service), CallControl or OPEN_URL before any key existed, and the phone
     * acted on them. Pre-handshake, only the Mac's handshake reply may land.
     */
    @Test
    fun plaintextCommandBeforeHandshakeDropsTheLink() {
        ServerSocket(0).use { server ->
            val delivered = AtomicInteger()
            val lost = CountDownLatch(1)
            val socket = BridgSocket()
            socket.setReceiveListener { delivered.incrementAndGet() }
            socket.setConnectionListener(object : BridgSocket.ConnectionListener {
                override fun onConnected() {}
                override fun onDisconnected() {}
                override fun onConnectionFailed(error: Exception) {}
                override fun onConnectionLost(error: Exception) = lost.countDown()
            })
            runBlocking { socket.connect("127.0.0.1", server.localPort) }
            server.accept().use { rogue ->
                val out = java.io.DataOutputStream(rogue.getOutputStream())
                FrameCodec.writeFrame(
                    out,
                    Envelope.newBuilder()
                        .setInputEvent(com.bridg.proto.InputEvent.newBuilder().setType(com.bridg.proto.InputEvent.EventType.TAP))
                        .build().toByteArray()
                )
                out.flush()
                assertTrue(lost.await(2, TimeUnit.SECONDS))
            }
            assertEquals(0, delivered.get())
            assertFalse(socket.isConnected())
        }
    }

    /**
     * When the Mac quits or relaunches it closes the socket cleanly, and the
     * read loop treated end-of-stream as a quiet exit. Nothing reported the
     * loss, so the phone sat on the dead socket, still "connected", and never
     * redialled.
     */
    @Test
    fun peerClosingTheSocketReportsTheLoss() {
        ServerSocket(0).use { server ->
            val lost = CountDownLatch(1)
            val socket = BridgSocket()
            socket.setConnectionListener(object : BridgSocket.ConnectionListener {
                override fun onConnected() {}
                override fun onDisconnected() {}
                override fun onConnectionFailed(error: Exception) {}
                override fun onConnectionLost(error: Exception) = lost.countDown()
            })
            runBlocking { socket.connect("127.0.0.1", server.localPort) }
            server.accept().close()

            assertTrue(lost.await(2, TimeUnit.SECONDS))
            assertFalse(socket.isConnected())
        }
    }
}

class UpdateVersionTest {
    private fun newer(a: String, b: String) = com.bridg.update.UpdateChecker.isNewer(a, b)

    @Test
    fun comparesNumericallyNotAsText() {
        assertTrue(newer("0.10.0", "0.9.3"))
        assertTrue(newer("0.3.3", "0.3.2"))
        assertTrue(newer("1.0", "0.9.9"))
        assertFalse(newer("0.3.2", "0.3.2"))
        assertFalse(newer("0.3", "0.3.0"))
        assertFalse(newer("0.3.1", "0.3.2"))
    }
}

/**
 * The Mac advertises this in its Bonjour TXT `id`, and the phone dials only
 * services whose id matches a paired computer. Same vector as
 * testHubTagMatchesTheAndroidVector on the Mac.
 */
class HubTagTest {
    @Test
    fun matchesTheMacVector() {
        val key = ByteArray(32) { it.toByte() }
        assertEquals("630dcd2966c43366", com.bridg.pairing.KeyManager.hubTag(key))
    }
}

/**
 * A computer answering at another's old address accepted the resume and then
 * failed the first sealed frame; with an immediate redial the phone looped
 * ~1,000 times in 15 minutes. Failures back off; a working session resets it.
 */
class RetryBackoffTest {
    private fun delay(n: Int) = com.bridg.service.BridgService.retryDelayMs(n)

    @Test
    fun doublesFromFiveSecondsAndCapsAtAMinute() {
        assertEquals(listOf(5_000L, 5_000L, 10_000L, 20_000L, 40_000L, 60_000L, 60_000L),
            listOf(0, 1, 2, 3, 4, 5, 50).map(::delay))
    }
}
