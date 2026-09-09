package com.bridg.media

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.bridg.notify.BridgNotificationListenerService
import com.bridg.proto.MediaCommand
import com.bridg.proto.MediaState

/**
 * Mirrors whatever is playing on the phone (Spotify, Apple Music, YouTube…)
 * to the Mac and lets the Mac drive it.
 *
 * This reads MediaSession, not the player's notification. Media notifications
 * re-post on every position tick and every metadata refresh, which is what made
 * music "come on repeat" on the Mac — the notification listener now drops them
 * and this channel carries the state instead.
 *
 * Needs the same notification-listener grant we already ask for.
 */
class MediaControl(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())
    private var manager: MediaSessionManager? = null
    private var controller: MediaController? = null
    private var onState: ((MediaState) -> Unit)? = null
    private var lastSent: MediaState? = null

    private val controllerCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onMetadataChanged(metadata: android.media.MediaMetadata?) = publish()
        override fun onSessionDestroyed() = refresh()
    }

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { refresh() }

    fun start(onState: (MediaState) -> Unit) {
        this.onState = onState
        val listener = ComponentName(context, BridgNotificationListenerService::class.java)
        val msm = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        manager = msm
        try {
            msm.addOnActiveSessionsChangedListener(sessionsListener, listener, main)
        } catch (e: SecurityException) {
            // Notification access not granted yet — BridgService retries on the
            // listener's own connect callback.
            Log.w(TAG, "Media sessions unavailable: ${e.message}")
            return
        }
        refresh()
    }

    fun stop() {
        controller?.unregisterCallback(controllerCallback)
        controller = null
        try {
            manager?.removeOnActiveSessionsChangedListener(sessionsListener)
        } catch (e: Exception) {
            Log.w(TAG, "Error removing session listener: ${e.message}")
        }
        manager = null
        onState = null
        lastSent = null
    }

    /** Re-send current state, e.g. right after a (re)connect. */
    fun resend() {
        lastSent = null
        publish()
    }

    fun handleCommand(action: MediaCommand.Action) {
        val transport = controller?.transportControls ?: return
        when (action) {
            MediaCommand.Action.PLAY_PAUSE ->
                if (controller?.playbackState?.state == PlaybackState.STATE_PLAYING) transport.pause()
                else transport.play()
            MediaCommand.Action.NEXT -> transport.skipToNext()
            MediaCommand.Action.PREVIOUS -> transport.skipToPrevious()
            else -> Log.w(TAG, "Unhandled media action: $action")
        }
    }

    /** Pick the session to mirror: whatever is playing, else the most recent. */
    private fun refresh() {
        val listener = ComponentName(context, BridgNotificationListenerService::class.java)
        val sessions = try {
            manager?.getActiveSessions(listener).orEmpty()
        } catch (e: SecurityException) {
            emptyList()
        }
        val next = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: sessions.firstOrNull()

        if (next?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(controllerCallback)
            controller = next
            next?.registerCallback(controllerCallback, main)
        }
        publish()
    }

    private fun publish() {
        val send = onState ?: return
        val state = buildState()
        // Sessions fire several callbacks for one change; only the Mac-visible
        // fields matter, so don't put the same card on the wire twice.
        if (state == lastSent) return
        lastSent = state
        send(state)
    }

    private fun buildState(): MediaState {
        val ctrl = controller ?: return MediaState.newBuilder().setActive(false).build()
        val metadata = ctrl.metadata
        val title = metadata?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE).orEmpty()
        // Nothing to show and nothing to control — treat it as no session.
        if (title.isEmpty()) return MediaState.newBuilder().setActive(false).build()

        return MediaState.newBuilder()
            .setActive(true)
            .setPackageName(ctrl.packageName)
            .setAppLabel(appLabel(ctrl.packageName))
            .setTitle(title)
            .setArtist(
                metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST)
                    ?: metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                    ?: ""
            )
            .setPlaying(ctrl.playbackState?.state == PlaybackState.STATE_PLAYING)
            .build()
    }

    private fun appLabel(packageName: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: Exception) {
        packageName
    }

    private companion object {
        const val TAG = "MediaControl"
    }
}
