package com.bridg.notify

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.bridg.proto.NotificationAction
import com.bridg.proto.NotificationEvent
import java.util.concurrent.ConcurrentHashMap

/**
 * Listens for phone notifications and forwards them to the connected Mac.
 * Filters out low-priority notifications and debounces rapid updates.
 */
class BridgNotificationListenerService : NotificationListenerService() {

    private val recentNotifications = ConcurrentHashMap<String, Long>()
    private var eventForwarder: NotificationEventForwarder? = null

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "Notification listener connected")
        // The system binds this service on its own schedule, independent of
        // BridgService — it can connect after BridgService already tried to
        // wire a forwarder into it. Completing the wiring from this side too
        // means whichever service starts last finishes the connection.
        com.bridg.service.BridgService.instance?.onNotificationListenerReady()
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
        Log.i(TAG, "Notification listener destroyed")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.notification?.category == Notification.CATEGORY_CALL) {
            Log.i(TAG, "call notification from ${sbn.packageName}, forwarder=${eventForwarder != null}")
        }
        if (shouldIgnore(sbn)) return

        val key = "${sbn.packageName}:${sbn.id}"
        val now = System.currentTimeMillis()
        val lastPosted = recentNotifications[key]

        // Debounce: ignore rapid updates within DEBOUNCE_MS (e.g., progress bar updates)
        if (lastPosted != null && now - lastPosted < DEBOUNCE_MS) {
            return
        }
        recentNotifications[key] = now

        val event = buildNotificationEvent(sbn)
        if (event != null) {
            eventForwarder?.onNotificationPosted(event)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val event = NotificationEvent.newBuilder()
            .setId("${sbn.packageName}:${sbn.id}")
            .setPackageName(sbn.packageName)
            .setAppLabel(getAppLabel(sbn.packageName))
            .setTimestamp(sbn.postTime)
            .build()

        eventForwarder?.onNotificationDismissed(event)
    }

    /**
     * Set the forwarder for sending events to the transport layer.
     */
    fun setEventForwarder(forwarder: NotificationEventForwarder) {
        eventForwarder = forwarder
    }

    /**
     * Send a reply that the user typed on the Mac.
     *
     * `notificationId` is the same "package:id" string we put on the wire. The
     * old version split that on ":" and read the notification id as an action
     * index, so it never matched a notification and never fired an intent.
     */
    fun handleReplyAction(notificationId: String, replyText: String) {
        val sbn = activeNotifications?.firstOrNull {
            "${it.packageName}:${it.id}" == notificationId
        } ?: run {
            Log.w(TAG, "No active notification for $notificationId")
            return
        }

        val action = sbn.notification.actions?.firstOrNull {
            !it.remoteInputs.isNullOrEmpty()
        } ?: run {
            Log.w(TAG, "Notification $notificationId has no reply action")
            return
        }

        try {
            // RemoteInput.addResultsToIntent is the required plumbing; stuffing
            // the text into a bare Bundle silently produced an empty reply.
            val intent = Intent()
            val results = Bundle()
            for (remoteInput in action.remoteInputs) {
                results.putCharSequence(remoteInput.resultKey, replyText)
            }
            RemoteInput.addResultsToIntent(action.remoteInputs, intent, results)
            action.actionIntent.send(this, 0, intent)
            Log.i(TAG, "Reply sent to $notificationId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send reply: ${e.message}")
        }
    }

    /** Re-forward every still-active call notification — used right after a (re)connect. */
    fun forwardActiveCalls() {
        val forwarder = eventForwarder ?: return
        activeNotifications?.filter {
            it.notification?.category == Notification.CATEGORY_CALL
        }?.forEach { sbn ->
            buildNotificationEvent(sbn)?.let {
                Log.i(TAG, "replaying active call ${it.id}")
                forwarder.onNotificationPosted(it)
            }
        }
    }

    private fun buildNotificationEvent(sbn: StatusBarNotification): NotificationEvent? {
        val notification = sbn.notification ?: return null
        val extras = notification.extras ?: return null

        val isCall = notification.category == Notification.CATEGORY_CALL
        var title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        var text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        // CallStyle notifications carry the caller in EXTRA_TITLE_BIG / the person,
        // and often leave EXTRA_TEXT empty. Give the Mac something to show.
        if (isCall) {
            if (title.isEmpty()) {
                title = extras.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString() ?: "Incoming call"
            }
            if (text.isEmpty()) text = "Incoming call"
        }

        val builder = NotificationEvent.newBuilder()
            .setId("${sbn.packageName}:${sbn.id}")
            .setPackageName(sbn.packageName)
            .setAppLabel(getAppLabel(sbn.packageName))
            .setTitle(title)
            .setText(text)
            .setTimestamp(sbn.postTime)
            .setIsCall(isCall)

        // Check for reply actions
        val actions = notification.actions
        if (actions != null) {
            var hasReplyAction = false
            for (action in actions) {
                val remoteInputs = action.remoteInputs
                if (remoteInputs != null && remoteInputs.isNotEmpty()) {
                    hasReplyAction = true
                }
                builder.addActions(
                    NotificationAction.newBuilder()
                        .setActionId("${sbn.packageName}:${sbn.id}")
                        .setLabel(action.title?.toString() ?: "")
                        .setIsReply(remoteInputs != null && remoteInputs.isNotEmpty())
                        .build()
                )
            }
            builder.setHasReplyAction(hasReplyAction)
        }

        return builder.build()
    }

    private fun shouldIgnore(sbn: StatusBarNotification): Boolean {
        // Ignore our own notifications
        if (sbn.packageName == packageName) return true

        // Call notifications are ongoing while ringing/active — never filter them.
        if (sbn.notification?.category == Notification.CATEGORY_CALL) return false

        // Ignore ongoing media notifications
        if (sbn.isOngoing) return true

        // Ignore group summaries (handled by individual notifications)
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return true

        // Could add per-app filtering here (user preferences)
        return false
    }

    private fun getAppLabel(packageName: String): String {
        return try {
            val pm = packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    interface NotificationEventForwarder {
        fun onNotificationPosted(event: NotificationEvent)
        fun onNotificationDismissed(event: NotificationEvent)
    }

    companion object {
        private const val TAG = "BridgNotificationListener"
        private const val DEBOUNCE_MS = 500L // Don't forward same notification within 500ms

        var instance: BridgNotificationListenerService? = null
            private set
    }
}
