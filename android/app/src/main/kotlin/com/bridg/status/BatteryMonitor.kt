package com.bridg.status

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import com.bridg.proto.DeviceStatus

/**
 * Watches the battery and reports it to the Mac.
 *
 * `ACTION_BATTERY_CHANGED` is a sticky broadcast that fires on every voltage
 * and temperature tick — many times a minute — while the number the Mac
 * displays changes maybe once every few minutes. Forwarding every broadcast
 * would be almost entirely wire churn, so [shouldForward] gates it.
 */
class BatteryMonitor(private val context: Context) {

    /** What we last told the Mac. Null until the first report. */
    private var lastSent: DeviceStatus? = null

    private var receiver: BroadcastReceiver? = null
    private var onChanged: ((DeviceStatus) -> Unit)? = null

    fun start(onChanged: (DeviceStatus) -> Unit) {
        if (receiver != null) return
        this.onChanged = onChanged

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                intent?.let { report(read(it)) }
            }
        }
        this.receiver = receiver

        // registerReceiver returns the sticky value straight away, so this both
        // subscribes and gives us the current state for the first report.
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.let { report(read(it)) }
    }

    fun stop() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        onChanged = null
        lastSent = null
    }

    /**
     * Re-send the current state regardless of what we sent last.
     *
     * A reconnect gives the Mac a blank slate, and the battery may not change
     * again for minutes — without this the menu bar would sit empty until it did.
     */
    fun resend() {
        lastSent = null
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        sticky?.let { report(read(it)) }
    }

    private fun report(status: DeviceStatus) {
        if (!shouldForward(lastSent, status)) return
        lastSent = status
        onChanged?.invoke(status)
    }

    companion object {
        /**
         * Forward only when something the Mac renders actually changed.
         *
         * Kept static and free of Android types so it can be unit-tested on the
         * JVM, like the notification de-duplication it mirrors.
         */
        fun shouldForward(previous: DeviceStatus?, current: DeviceStatus): Boolean {
            if (previous == null) return true
            return previous.batteryPercent != current.batteryPercent ||
                previous.charging != current.charging ||
                previous.batteryLow != current.batteryLow
        }

        /** Pull the fields we care about out of an ACTION_BATTERY_CHANGED intent. */
        fun read(intent: Intent): DeviceStatus {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)

            // Scale is almost always 100, but the API does not promise it.
            val percent = if (level >= 0 && scale > 0) level * 100 / scale else 0

            return DeviceStatus.newBuilder()
                .setBatteryPercent(percent)
                .setCharging(
                    status == BatteryManager.BATTERY_STATUS_CHARGING ||
                        status == BatteryManager.BATTERY_STATUS_FULL
                )
                .setBatteryLow(intent.getBooleanExtra("battery_low", false))
                .build()
        }
    }
}
