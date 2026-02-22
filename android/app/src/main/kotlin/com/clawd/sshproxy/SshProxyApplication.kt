package com.clawd.sshproxy

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/**
 * Custom Application class that creates the notification channel as early as possible.
 *
 * This fixes the boot auto-start crash: when autoStartOnBoot is enabled,
 * flutter_background_service starts a foreground service before any Activity is created.
 * If the notification channel doesn't exist yet → BadNotificationException on Android 8+.
 *
 * Application.onCreate() runs before ANY component (Activity, Service, BroadcastReceiver),
 * so the channel is guaranteed to exist by the time the background service needs it.
 */
class SshProxyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel(this)
    }

    companion object {
        /**
         * Idempotent helper: creates the notification channel if it doesn't exist.
         * Safe to call multiple times — Android ignores duplicate channel creation.
         */
        fun ensureNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    "ssh_proxy_channel",
                    "SSH Proxy Service",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Keeps SSH tunnels alive in background"
                }
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.createNotificationChannel(channel)
            }
        }
    }
}
