package com.bridg.remote

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.bridg.BridgApplication
import com.bridg.R
import com.bridg.proto.RemoteAction

/**
 * One-shot commands from the Mac: ring the phone, open a link on it.
 */
class RemoteActionHandler(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())
    private var ringtone: Ringtone? = null

    /**
     * Held as one stable instance. A `::stopRing` method reference mints a new
     * object every time it is evaluated, so `removeCallbacks` would match
     * nothing and a stale timer from an earlier ring would cut the next one
     * short.
     */
    private val stopRinging = Runnable { stopRing() }

    /** Alarm volume before we turned it up, so ringing can put it back. */
    private var previousAlarmVolume: Int? = null

    fun handle(action: RemoteAction) {
        when (action.action) {
            RemoteAction.Action.RING -> ring()
            RemoteAction.Action.STOP_RING -> stopRing()
            RemoteAction.Action.OPEN_URL -> openUrl(action.url)
            else -> Log.w(TAG, "Unhandled remote action: ${action.action}")
        }
    }

    /**
     * Find-my-phone. Plays the alarm tone at full volume.
     *
     * The alarm stream is the point: it is the one channel that still sounds
     * when the phone is on silent, which is exactly the case where you cannot
     * find it.
     */
    fun ring() {
        stopRing()

        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Setting stream volume throws if Do Not Disturb is on and we do not
        // hold notification-policy access. Ringing at the current volume is
        // still better than not ringing.
        runCatching {
            previousAlarmVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
            audio.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0
            )
        }

        val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val tone = RingtoneManager.getRingtone(context, uri)
        if (tone == null) {
            Log.w(TAG, "No ringtone available to ring with")
            restoreAlarmVolume()
            return
        }

        tone.audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        // ponytail: below API 28 the tone plays once instead of looping. The
        // upgrade path is re-posting it on completion; one pass is enough to
        // locate a phone in the same room.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) tone.isLooping = true

        tone.play()
        ringtone = tone

        // Ringing forever is a worse bug than not ringing. You have found the
        // phone by now, and the Mac can stop it sooner with STOP_RING.
        handler.postDelayed(stopRinging, RING_TIMEOUT_MS)
        Log.i(TAG, "Ringing")
    }

    fun stopRing() {
        handler.removeCallbacks(stopRinging)
        ringtone?.runCatching { stop() }
        ringtone = null
        restoreAlarmVolume()
    }

    private fun restoreAlarmVolume() {
        val previous = previousAlarmVolume ?: return
        previousAlarmVolume = null
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, previous, 0) }
    }

    /**
     * Offer a link sent from the Mac.
     *
     * ponytail: this posts a heads-up notification to tap rather than opening
     * the browser outright. Android 10+ blocks apps from starting activities
     * from the background, and does it silently, so a direct `startActivity`
     * would work on some devices and quietly do nothing on others. The upgrade
     * path, if one tap is too many, is the SYSTEM_ALERT_WINDOW permission —
     * which is a large thing to ask for a small convenience.
     */
    fun openUrl(url: String) {
        if (!isAllowedUrl(url)) {
            Log.w(TAG, "Refusing to open a URL that is not http(s)")
            return
        }

        val view = PendingIntent.getActivity(
            context,
            URL_REQUEST_CODE,
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = Notification.Builder(context, BridgApplication.CHANNEL_ALERTS)
            .setContentTitle("Link from your Mac")
            .setContentText(url)
            .setStyle(Notification.BigTextStyle().bigText(url))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(view)
            .setAutoCancel(true)
            .build()

        val manager = context.getSystemService(NotificationManager::class.java)
        manager.notify(URL_NOTIFICATION_ID, notification)
    }

    companion object {
        private const val TAG = "RemoteActionHandler"
        private const val RING_TIMEOUT_MS = 30_000L
        private const val URL_NOTIFICATION_ID = 2
        private const val URL_REQUEST_CODE = 10

        /**
         * The Mac hands us a string and we hand it to the system to launch.
         * That is a trust boundary: `intent://` URIs can start arbitrary
         * components and `file://` can expose local storage, so only the two
         * schemes this feature is actually for get through.
         *
         * Written against java.net.URI rather than android.net.Uri so it can be
         * unit-tested on the JVM.
         */
        fun isAllowedUrl(raw: String): Boolean {
            val uri = runCatching { java.net.URI(raw.trim()) }.getOrNull() ?: return false
            val scheme = uri.scheme?.lowercase() ?: return false
            if (scheme != "http" && scheme != "https") return false
            return !uri.host.isNullOrBlank()
        }
    }
}
