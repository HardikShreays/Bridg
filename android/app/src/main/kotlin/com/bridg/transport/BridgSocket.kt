package com.bridg.transport

import android.util.Log
import com.bridg.proto.Envelope
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.io.*
import java.net.InetSocketAddress
import java.net.Socket

/**
 * A single TCP connection to the paired Mac. The phone is the client: the Mac
 * listens and advertises over Bonjour, we discover and dial in.
 */
class BridgSocket {

    private var socket: Socket? = null
    private var input: DataInputStream? = null
    private var output: DataOutputStream? = null

    @Volatile private var encryptedTransport: EncryptedTransport? = null

    private val sendQueue = Channel<Outgoing>(capacity = 256)

    /** Frames queued but not yet written, so video can shed load before the queue fills. */
    private val queueDepth = java.util.concurrent.atomic.AtomicInteger(0)
    @Volatile private var droppedSinceKeyframe = false
    private var receiveListener: ((Envelope) -> Unit)? = null
    private var connectionListener: ConnectionListener? = null

    private var sendJob: Job? = null
    private var receiveJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /** Set while a [connect] is dialling, so a racing second call backs off. */
    private val connecting = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Turn on encryption once the handshake has produced a session key.
     * Everything sent and received after this point is sealed.
     */
    fun setEncryptionKey(sharedKey: ByteArray) {
        encryptedTransport = EncryptedTransport(sharedKey, EncryptedTransport.DIRECTION_PHONE_TO_MAC)
    }

    fun clearEncryption() {
        encryptedTransport = null
    }

    /**
     * Dial the Mac. Returns false without dialling if another attempt is in
     * flight or the link is already up.
     *
     * Known-host dialling and Bonjour discovery both call this, often within
     * milliseconds. Letting both through opened two sockets that overwrote each
     * other's streams, each sent its own handshake, and the Mac cancelled the
     * first mid-handshake — so the link never authenticated and cycled through
     * "Broken pipe" forever.
     */
    suspend fun connect(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        if (!connecting.compareAndSet(false, true)) return@withContext false
        try {
            if (isConnected()) return@withContext false
            val s = Socket().apply {
                tcpNoDelay = true
                // Must exceed the Mac's 10s ping interval (or an idle but healthy
                // link is torn down on a read timeout), but low enough that a
                // dropped Wi-Fi / dead link is noticed promptly instead of the
                // app sitting on "Connected" for 40s. ~2.5 missed pings.
                soTimeout = 25_000
                connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            }
            socket = s
            input = DataInputStream(BufferedInputStream(s.getInputStream()))
            output = DataOutputStream(BufferedOutputStream(s.getOutputStream()))

            startSendLoop(s)
            startReceiveLoop(s)

            connectionListener?.onConnected()
            Log.i(TAG, "Connected to $host:$port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}")
            connectionListener?.onConnectionFailed(e)
            false
        } finally {
            connecting.set(false)
        }
    }

    /**
     * Queue an envelope. It is encrypted on the way out if a session key is set.
     *
     * The old `sendEncrypted` encrypted the payload and then threw the result
     * away, sending an empty Ping in its place.
     */
    fun send(envelope: Envelope) {
        val result = sendQueue.trySend(Outgoing(envelope))
        if (result.isFailure) Log.w(TAG, "Send queue full — dropping ${envelope.payloadCase}")
    }

    /**
     * Queue a video frame, dropping it if the socket is already behind.
     *
     * A stale mirror frame is worthless — showing it late is worse than not
     * showing it — but [send] queued every one regardless, so a slow link built
     * a backlog the mirror never recovered from. Drop non-keyframes past the
     * watermark and let the caller ask the encoder for a fresh keyframe; that
     * bounds latency instead of letting it grow.
     *
     * Returns true if the stream was interrupted and needs a keyframe.
     */
    fun sendVideoFrame(envelope: Envelope, isKeyframe: Boolean): Boolean {
        if (!isKeyframe && queueDepth.get() >= VIDEO_DROP_WATERMARK) {
            droppedSinceKeyframe = true
            return false
        }
        queueDepth.incrementAndGet()
        if (sendQueue.trySend(Outgoing(envelope)).isFailure) {
            queueDepth.decrementAndGet()
            droppedSinceKeyframe = true
            return false
        }
        // The stream has a hole in it; only a keyframe closes it.
        return droppedSinceKeyframe.also { if (it) droppedSinceKeyframe = false }
    }

    /**
     * Blocking enqueue for bulk producers (file chunks). A big file generates
     * chunks far faster than the socket drains them; [send]'s `trySend` then
     * silently dropped chunks once the 256-deep queue filled, so the receiver
     * saw gaps and the transfer either stalled or finished corrupt. This
     * back-pressures the producer instead. Safe only off the receive thread —
     * the file sender runs on its own dedicated thread.
     */
    fun sendBlocking(envelope: Envelope) {
        runBlocking { sendQueue.send(Outgoing(envelope)) }
    }

    private data class Outgoing(val envelope: Envelope)

    fun setReceiveListener(listener: (Envelope) -> Unit) { receiveListener = listener }

    fun setConnectionListener(listener: ConnectionListener) { connectionListener = listener }

    fun disconnect() {
        sendJob?.cancel()
        receiveJob?.cancel()
        try { socket?.close() } catch (e: Exception) { Log.w(TAG, "Error closing socket: ${e.message}") }
        socket = null
        input = null
        output = null
        clearEncryption()
        connectionListener?.onDisconnected()
    }

    fun isConnected(): Boolean = socket?.let { it.isConnected && !it.isClosed } == true

    private fun startSendLoop(s: Socket) {
        sendJob?.cancel()
        sendJob = scope.launch {
            // A channel blocks until there is work; the old loop polled a queue
            // with a 1ms delay and burned CPU whenever the link was idle.
            for (outgoing in sendQueue) {
                // Only video is counted; the watermark measures video backlog.
                if (outgoing.envelope.hasVideoFrame()) queueDepth.decrementAndGet()
                val out = output ?: break
                val envelope = outgoing.envelope
                try {
                    var bytes = envelope.toByteArray()
                    val transport = encryptedTransport
                    if (transport != null) {
                        bytes = transport.encrypt(bytes) ?: run {
                            Log.e(TAG, "Encryption failed — dropping ${envelope.payloadCase}")
                            null
                        } ?: continue
                    }
                    FrameCodec.writeFrame(out, bytes)
                } catch (e: IOException) {
                    Log.e(TAG, "Send error: ${e.message}")
                    lost(s, e)
                    break
                }
            }
        }
    }

    private fun startReceiveLoop(s: Socket) {
        receiveJob?.cancel()
        receiveJob = scope.launch {
            while (isActive) {
                try {
                    val frame = FrameCodec.readFrame(input ?: break) ?: break
                    val transport = encryptedTransport
                    val bytes = if (transport != null) transport.decrypt(frame) else frame
                    if (bytes == null) {
                        // A frame that will not open is a replay, a forgery or a
                        // key mismatch. None of those get better by reading the
                        // next frame, so drop the link instead of looping.
                        Log.e(TAG, "Rejected frame — dropping connection")
                        lost(s, IOException("frame rejected"))
                        break
                    }
                    receiveListener?.invoke(Envelope.parseFrom(bytes))
                } catch (e: IOException) {
                    if (isActive) {
                        Log.e(TAG, "Receive error: ${e.message}")
                        lost(s, e)
                    }
                    break
                }
            }
        }
    }

    /**
     * Close the socket a loop was serving, then report the loss once.
     *
     * The socket used to stay open after a loss, so [isConnected] kept saying
     * true and [connect] would refuse every reconnect. The identity check keeps
     * the second loop of a dead link — or a loop outliving its socket — from
     * reporting again or closing a newer connection.
     */
    private fun lost(s: Socket, e: Exception) {
        synchronized(this) {
            if (s !== socket) return
            socket = null
            input = null
            output = null
        }
        runCatching { s.close() }
        connectionListener?.onConnectionLost(e)
    }

    interface ConnectionListener {
        fun onConnected()
        fun onDisconnected()
        fun onConnectionFailed(error: Exception)
        fun onConnectionLost(error: Exception)
    }

    companion object {
        private const val TAG = "BridgSocket"
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val VIDEO_DROP_WATERMARK = 128 // half the queue
    }
}
