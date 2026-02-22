package com.clawd.sshproxy

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            // Start the main activity which will initialize the Flutter engine
            // and the background service (configured with autoStartOnBoot)
            val serviceIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("autostart", true)
            }
            // On Android 10+ we might not be able to start activities from background
            // but the flutter_background_service autoStartOnBoot handles the foreground service
            try {
                context.startActivity(serviceIntent)
            } catch (e: Exception) {
                // Fallback: the flutter_background_service plugin handles boot via its own receiver
                // when autoStartOnBoot is true in AndroidConfiguration
                android.util.Log.w("BootReceiver", "Could not start activity on boot: ${e.message}")
            }
        }
    }
}
