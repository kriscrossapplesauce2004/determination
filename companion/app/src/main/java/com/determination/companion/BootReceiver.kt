package com.determination.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restores the optional presenter only when the user explicitly left it enabled. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED) return
        if (ExternalDisplayState.read(context).enabled) {
            context.startForegroundService(ExternalDisplayService.startIntent(context))
        }
    }
}
