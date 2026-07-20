package com.determination.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts the optional external-display presenter; core services live in detd. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED) return
        context.startForegroundService(Intent(context, ExternalDisplayService::class.java))
    }
}
