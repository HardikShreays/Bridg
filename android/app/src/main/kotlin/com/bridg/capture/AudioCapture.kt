package com.bridg.capture

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import kotlin.concurrent.thread

/**
 * Captures the phone's own audio output through the same MediaProjection the
 * screen mirror uses, so what you see on the Mac is what you hear.
 *
 * Playback capture is API 29+ and only yields audio from apps that haven't
 * opted out (`allowAudioPlaybackCapture=false`), so this is always best-effort:
 * a phone that can't do it still mirrors video.
 */
class AudioCapture {

    private var record: AudioRecord? = null
    @Volatile private var running = false

    /** Raw 16-bit little-endian interleaved PCM, ~20 ms per call. */
    fun interface PcmSink {
        fun onPcm(pcm: ByteArray, sampleRate: Int, channels: Int)
    }

    @SuppressLint("MissingPermission")
    fun start(projection: MediaProjection, sink: PcmSink) {
        if (running) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(TAG, "Playback capture needs Android 10+; mirroring video only")
            return
        }

        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT
        )
        val recorder = try {
            AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minBuffer, CHUNK_BYTES * 4))
                .build()
        } catch (e: Exception) {
            // Missing RECORD_AUDIO, or an OEM that refuses playback capture.
            Log.w(TAG, "Audio capture unavailable: ${e.message}")
            return
        }

        record = recorder
        running = true
        recorder.startRecording()
        Log.i(TAG, "Audio capture started")

        thread(name = "BridgAudioCapture") {
            val buffer = ByteArray(CHUNK_BYTES)
            while (running) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read <= 0) continue
                sink.onPcm(
                    if (read == buffer.size) buffer.copyOf() else buffer.copyOf(read),
                    SAMPLE_RATE,
                    CHANNELS
                )
            }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        try {
            record?.stop()
            record?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping audio capture: ${e.message}")
        }
        record = null
        Log.i(TAG, "Audio capture stopped")
    }

    private companion object {
        const val TAG = "AudioCapture"
        const val SAMPLE_RATE = 48_000
        const val CHANNELS = 2
        const val CHUNK_BYTES = SAMPLE_RATE / 50 * CHANNELS * 2 // 20 ms
    }
}
