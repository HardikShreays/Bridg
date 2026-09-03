package com.bridg.capture

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface

/**
 * Handles screen capture using MediaProjection + VirtualDisplay + MediaCodec (H.264).
 * Encodes captured frames as H.264 NAL units for transmission over the transport layer.
 */
class ScreenCapture(private val context: Context) {

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null

    private var captureThread: HandlerThread? = null
    private var captureHandler: Handler? = null

    private var isCapturing = false
    private var frameCallback: FrameCallback? = null

    /** Read by the service so the stream header matches what is encoded. */
    var width = DEFAULT_WIDTH
        private set
    var height = DEFAULT_HEIGHT
        private set
    private var fps = DEFAULT_FPS
    private var bitrate = DEFAULT_BITRATE

    /**
     * Start screen capture with the given MediaProjection.
     */
    fun startCapture(projection: MediaProjection, callback: FrameCallback) {
        if (isCapturing) return

        frameCallback = callback
        mediaProjection = projection
        resolveCaptureSize()

        captureThread = HandlerThread("ScreenCapture").apply { start() }
        captureHandler = Handler(captureThread!!.looper)

        setupEncoder()

        // From API 34 on, createVirtualDisplay() throws IllegalStateException if
        // no MediaProjection.Callback has been registered yet — which crashed the
        // app the moment mirroring was started. Registration must come first.
        //
        // The callback runs on the main looper, not captureHandler: the capture
        // thread is blocked in the drain loop below and would never deliver it.
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "MediaProjection stopped")
                stopCapture()
            }
        }, Handler(Looper.getMainLooper()))

        setupVirtualDisplay()

        isCapturing = true
        // Nothing ever called drainEncoder(), so no encoded frame ever left the
        // phone and the encoder stalled once its output buffers filled.
        captureHandler!!.post { drainLoop() }
        Log.i(TAG, "Screen capture started: ${width}x${height} @ ${fps}fps")
    }

    /**
     * Encode at the display's real aspect ratio, capped at [MAX_SHORT_EDGE].
     *
     * The old code hardcoded 1080x1920 while the service advertised the true
     * display metrics to the Mac, so the decoder was told dimensions the stream
     * never had.
     */
    private fun resolveCaptureSize() {
        val metrics = context.resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        val shortEdge = minOf(w, h)
        val scale = if (shortEdge > MAX_SHORT_EDGE) MAX_SHORT_EDGE.toFloat() / shortEdge else 1f
        // H.264 requires even dimensions.
        width = ((w * scale).toInt() / 2) * 2
        height = ((h * scale).toInt() / 2) * 2
    }

    /**
     * Stop screen capture and release resources.
     */
    fun stopCapture() {
        if (!isCapturing) return
        isCapturing = false

        // Release on the capture thread so it happens *after* drainLoop() has
        // returned. Releasing a MediaCodec while another thread sits inside
        // dequeueOutputBuffer() is a native crash.
        val handler = captureHandler
        val thread = captureThread
        val teardown = Runnable {
            try {
                encoder?.signalEndOfInputStream()
                encoder?.stop()
                encoder?.release()
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping encoder: ${e.message}")
            }

            try {
                virtualDisplay?.release()
            } catch (e: Exception) {
                Log.w(TAG, "Error releasing virtual display: ${e.message}")
            }

            try {
                inputSurface?.release()
            } catch (e: Exception) {
                Log.w(TAG, "Error releasing input surface: ${e.message}")
            }

            try {
                mediaProjection?.stop()
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping projection: ${e.message}")
            }

            encoder = null
            inputSurface = null
            virtualDisplay = null
            mediaProjection = null
            frameCallback = null

            thread?.quitSafely()
            Log.i(TAG, "Screen capture stopped")
        }

        if (handler == null || !handler.post(teardown)) teardown.run()
        captureThread = null
        captureHandler = null
    }

    /**
     * Update the bitrate (e.g., in response to network congestion).
     */
    fun setBitrate(newBitrate: Int) {
        bitrate = newBitrate
        encoder?.let { codec ->
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate)
            }
            codec.setParameters(params)
        }
    }

    /**
     * Request a keyframe (e.g., after reconnect).
     */
    fun requestKeyframe() {
        encoder?.let { codec ->
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            codec.setParameters(params)
        }
    }

    private fun setupEncoder() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
        }

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = createInputSurface()
            start()
        }
    }

    private fun setupVirtualDisplay() {
        val displayManager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val density = context.resources.displayMetrics.densityDpi

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            captureHandler
        )
    }

    /**
     * Pump encoded output for as long as capture is running.
     *
     * Runs on the capture thread and blocks there; the codec-config buffer
     * (SPS/PPS) arrives here as the first output, which is why the old
     * extractSpsPps() — which drained *before* the VirtualDisplay existed and
     * so before any frame could be produced — never found it.
     */
    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()

        while (isCapturing) {
            val codec = encoder ?: return
            val index = try {
                codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            } catch (e: IllegalStateException) {
                return // stopCapture() got there first
            }
            if (index < 0) continue

            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                val data = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                buffer.get(data)

                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    frameCallback?.onConfigFrame(data)
                } else {
                    frameCallback?.onVideoFrame(
                        data,
                        info.presentationTimeUs,
                        info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    )
                }
            }

            codec.releaseOutputBuffer(index, false)

            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
    }

    interface FrameCallback {
        fun onConfigFrame(spsPps: ByteArray)
        fun onVideoFrame(nalUnits: ByteArray, pts: Long, isKeyframe: Boolean)
    }

    companion object {
        private const val TAG = "ScreenCapture"
        private const val VIRTUAL_DISPLAY_NAME = "BridgMirror"
        private const val DEFAULT_WIDTH = 1080
        private const val DEFAULT_HEIGHT = 1920
        private const val MAX_SHORT_EDGE = 1080
        private const val DEQUEUE_TIMEOUT_US = 100_000L
        private const val DEFAULT_FPS = 30
        private const val DEFAULT_BITRATE = 8_000_000 // 8 Mbps
        private const val I_FRAME_INTERVAL = 2 // seconds
    }
}
