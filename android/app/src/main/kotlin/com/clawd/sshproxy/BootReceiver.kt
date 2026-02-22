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
            // Do NOT start Activity from background — it crashes on Android 10+ (API 29+).
            // The flutter_background_service plugin handles boot auto-start via its own
            // mechanism when autoStartOnBoot is set to true in AndroidConfiguration.
            Log.i("BootReceiver", "Boot completed — flutter_background_service handles auto-start")
        }
    }
}
