package com.bridg

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class BridgApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        val serviceChannel = NotificationChannel(
            CHANNEL_SERVICE,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }

        // Links pushed from the Mac. High importance so it arrives as a
        // heads-up banner you can tap straight away — a link you asked for on
        // your phone is worthless if you have to go hunting in the shade.
        val alertsChannel = NotificationChannel(
            CHANNEL_ALERTS,
            getString(R.string.alerts_channel_name),
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = getString(R.string.alerts_channel_description)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(serviceChannel)
        notificationManager.createNotificationChannel(alertsChannel)
    }

    companion object {
        const val CHANNEL_SERVICE = "bridg_service"
        const val CHANNEL_ALERTS = "bridg_alerts"
    }
}
