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

    suspend fun connect(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        try {
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

            startSendLoop()
            startReceiveLoop()

            connectionListener?.onConnected()
            Log.i(TAG, "Connected to $host:$port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}")
            connectionListener?.onConnectionFailed(e)
            false
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

    /**
     * Send this frame in the clear, then switch the link to encrypted.
     *
     * The switch has to happen on the send loop itself: the Mac turns on
     * encryption the moment it reads our PairResume, so installing the key from
     * the caller would race the queue and either seal the handshake frame or
     * miss the Mac's already-encrypted reply.
     */
    fun sendThenEncrypt(envelope: Envelope, sharedKey: ByteArray) {
        val result = sendQueue.trySend(Outgoing(envelope, sharedKey))
        if (result.isFailure) Log.w(TAG, "Send queue full — handshake dropped")
    }

    private data class Outgoing(val envelope: Envelope, val installKeyAfterSend: ByteArray? = null)

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

    private fun startSendLoop() {
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
                    outgoing.installKeyAfterSend?.let { setEncryptionKey(it) }
                } catch (e: IOException) {
                    Log.e(TAG, "Send error: ${e.message}")
                    connectionListener?.onConnectionLost(e)
                    break
                }
            }
        }
    }

    private fun startReceiveLoop() {
        receiveJob?.cancel()
        receiveJob = scope.launch {
            while (isActive) {
                try {
                    val frame = FrameCodec.readFrame(input ?: break) ?: break
                    val transport = encryptedTransport
                    val bytes = if (transport != null) transport.decrypt(frame) ?: continue else frame
                    receiveListener?.invoke(Envelope.parseFrom(bytes))
                } catch (e: IOException) {
                    if (isActive) {
                        Log.e(TAG, "Receive error: ${e.message}")
                        connectionListener?.onConnectionLost(e)
                    }
                    break
                }
            }
        }
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
