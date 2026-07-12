package com.determination.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Starts the AudioBridgeService at boot so guest playback works without any
 * per-boot user tap. The service is a foreground FGS with a low-importance
 * notification, which is the AOSP-blessed way to hold a network port + audio
 * without app-process death.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED) return
        val svc = Intent(context, AudioBridgeService::class.java)
        context.startForegroundService(svc)
    }
}
