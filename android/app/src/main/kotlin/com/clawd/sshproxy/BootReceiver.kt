package com.clawd.sshproxy

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON"
        ) {
            // Belt-and-suspenders: ensure the notification channel exists.
            // SshProxyApplication.onCreate() already creates it, but in rare
            // edge cases (e.g. direct-boot aware receivers) this is a safety net.
            SshProxyApplication.ensureNotificationChannel(context)

            // Do NOT start Activity from background — it crashes on Android 10+ (API 29+).
            // The flutter_background_service plugin handles boot auto-start via its own
            // mechanism when autoStartOnBoot is set to true in AndroidConfiguration.
            Log.i("BootReceiver", "Boot completed — notification channel ensured, flutter_background_service handles auto-start")
        }
    }
}
