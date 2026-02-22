package com.clawd.sshproxy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    /**
     * Create the notification channel used by flutter_background_service.
     *
     * flutter_background_service only auto-creates its default channel
     * ("FOREGROUND_DEFAULT"). When a custom notificationChannelId is specified
     * in AndroidConfiguration, the channel MUST already exist — otherwise the
     * foreground service notification silently fails on Android 8+ (API 26+),
     * which can cause the service to crash or be killed by the OS.
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "ssh_proxy_channel",
                "SSH Proxy Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps SSH tunnels alive in background"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
