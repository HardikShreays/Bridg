package com.bridg.clipboard

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.bridg.proto.ClipboardUpdate
import java.util.UUID

/**
 * Manages clipboard synchronization between Android and Mac.
 * Uses polling with an origin tag to prevent echo loops.
 *
 * Renamed to BridgClipboardManager to avoid collision with android.content.ClipboardManager.
 */
class BridgClipboardManager(private val context: Context) {

    private val systemClipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    private val handler = Handler(Looper.getMainLooper())

    private val deviceId = UUID.randomUUID().toString()
    private var clipListener: android.content.ClipboardManager.OnPrimaryClipChangedListener? = null
    private var clipboardForwarder: ClipboardForwarder? = null

    /**
     * Text we just wrote from a remote update — the next OnPrimaryClipChanged
     * firing for it is our own echo, not a real local copy, and must not be
     * forwarded back. Content-based, matching the (already-fixed) Mac side:
     * comparing this update's originId against the *remote's* id can never
     * match our own outgoing update, whose originId is always our own device.
     */
    private var appliedFromRemote: String? = null

    /**
     * Start monitoring the clipboard for changes.
     */
    fun startMonitoring(forwarder: ClipboardForwarder) {
        clipboardForwarder = forwarder

        clipListener = android.content.ClipboardManager.OnPrimaryClipChangedListener {
            syncCurrentClip()
        }

        systemClipboardManager.addPrimaryClipChangedListener(clipListener)
        Log.i(TAG, "Clipboard monitoring started")
    }

    /**
     * Read the system clipboard and forward it to the Mac.
     *
     * Since Android 10 `getPrimaryClip()` returns null unless the calling app
     * has window focus (or is the default IME). Bridg reads it from a
     * background foreground-service, so the change listener fired but always
     * got null and nothing was ever forwarded — the clipboard synced Mac→phone
     * only. Nothing in an app's power lifts that restriction, so the other call
     * site is [com.bridg.ui.MainActivity]'s `onResume`, where we do have focus:
     * opening Bridg pushes whatever is on the phone's clipboard.
     */
    fun syncCurrentClip() {
        val clip = systemClipboardManager.primaryClip
        if (clip == null || clip.itemCount == 0) {
            // Not an error: this is the normal background result on Android 10+.
            Log.d(TAG, "Clipboard unreadable (no window focus) — nothing forwarded")
            return
        }

        val item = clip.getItemAt(0)

        val builder = ClipboardUpdate.newBuilder()
            .setOriginId(deviceId)
            .setTimestamp(System.currentTimeMillis())

        val text = item.text
        if (text != null) {
            builder.setContent(text.toString())
            builder.setMimeType("text/plain")
        } else if (item.uri != null) {
            // Our own FileProvider Uri is an image we just applied from the Mac.
            if (item.uri.authority == authority) return
            val bytes = readImage(item.uri) ?: return
            builder.setImageData(com.google.protobuf.ByteString.copyFrom(bytes))
            builder.setMimeType("image/*")
            clipboardForwarder?.onClipboardChanged(builder.build())
            return
        } else {
            return
        }

        val update = builder.build()

        // Don't echo back the item we just applied from the Mac.
        val applied = appliedFromRemote
        appliedFromRemote = null
        if (applied != null && update.content == applied) return

        clipboardForwarder?.onClipboardChanged(update)
    }

    /**
     * Stop monitoring the clipboard.
     */
    fun stopMonitoring() {
        clipListener?.let { systemClipboardManager.removePrimaryClipChangedListener(it) }
        clipListener = null
        clipboardForwarder = null
        Log.i(TAG, "Clipboard monitoring stopped")
    }

    /**
     * Handle a clipboard update received from the Mac.
     */
    fun handleRemoteClipboard(update: ClipboardUpdate) {
        // Echo prevention is the origin id alone. The old timestamp guard
        // rejected anything LESS than 2s old — i.e. every update that arrived
        // promptly over the LAN, which is nearly all of them. Confirmed by a
        // soak test: with that guard in place, only updates that happened to
        // take >2s end-to-end ever got applied.
        if (update.originId == deviceId) return

        appliedFromRemote = update.content

        handler.post {
            if (!update.imageData.isEmpty) {
                // Another app can only paste a content:// Uri, so the bytes go
                // to a cache file served by our FileProvider. One file, overwritten.
                val file = java.io.File(context.cacheDir, "shared/clipboard.img")
                file.parentFile?.mkdirs()
                file.writeBytes(update.imageData.toByteArray())
                val uri = androidx.core.content.FileProvider.getUriForFile(context, authority, file)
                systemClipboardManager.setPrimaryClip(
                    android.content.ClipData.newUri(context.contentResolver, "bridg_sync", uri)
                )
            } else if (update.content.isNotEmpty()) {
                val clip = android.content.ClipData.newPlainText(
                    "bridg_sync",
                    update.content
                )
                systemClipboardManager.setPrimaryClip(clip)
                Log.d(TAG, "Remote clipboard synced: ${update.content.take(50)}...")
            }
        }
    }

    private val authority = "${context.packageName}.fileprovider"

    /**
     * Image bytes behind a copied Uri, or null if it isn't an image. Anything
     * over the cap is re-encoded at half size: a whole update must fit in one
     * 4 MB transport frame, and phone photos routinely don't.
     */
    private fun readImage(uri: android.net.Uri): ByteArray? = try {
        val type = context.contentResolver.getType(uri)
        if (type?.startsWith("image/") != true) null
        else {
            val raw = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (raw == null || raw.size <= MAX_IMAGE_SIZE) raw
            else {
                val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = 2 }
                val bmp = android.graphics.BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)
                java.io.ByteArrayOutputStream().also { bmp?.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                    .toByteArray().takeIf { it.isNotEmpty() && it.size <= MAX_IMAGE_SIZE }
                    .also { if (it == null) Log.w(TAG, "Copied image too large to sync") }
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "Cannot read copied image: ${e.message}")
        null
    }

    /**
     * Get the device's unique ID for echo prevention.
     */
    fun getDeviceId(): String = deviceId

    companion object {
        private const val TAG = "BridgClipboard"
        /** Must fit one transport frame (FrameCodec.MAX_FRAME_SIZE, 4 MB) with room for the envelope. */
        const val MAX_IMAGE_SIZE = 3 * 1024 * 1024
    }

    interface ClipboardForwarder {
        fun onClipboardChanged(update: ClipboardUpdate)
    }
}
