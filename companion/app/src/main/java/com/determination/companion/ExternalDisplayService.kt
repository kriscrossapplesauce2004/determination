package com.determination.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Owns only the optional Android presentation surface used for concurrent
 * external-display convergence. It never transports audio or controls the
 * guest lifecycle; detd and the guest compositor remain independent.
 */
class ExternalDisplayService : Service() {
    companion object {
        private const val TAG = "DetExternalService"
        private const val NOTIFICATION_CHANNEL = "det-external-display"
        private const val NOTIFICATION_ID = 0x0DE8
    }

    private var presenter: ExternalDisplayPresenter? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (error: Exception) {
            // A denied FGS must not crash-loop the companion. The presenter is
            // still useful while the process remains alive and detd can retry
            // it after a later display hotplug.
            Log.w(TAG, "foreground start denied: ${error.message}")
        }
        presenter = ExternalDisplayPresenter(this).also { it.start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        presenter?.stop()
        presenter = null
        super.onDestroy()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                getString(R.string.external_display_channel),
                NotificationManager.IMPORTANCE_MIN,
            ).apply { setShowBadge(false) },
        )
    }

    private fun notification(): Notification =
        Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setContentTitle(getString(R.string.external_display_notif))
            .setSmallIcon(R.drawable.ic_desktop)
            .setOngoing(true)
            .build()
}
