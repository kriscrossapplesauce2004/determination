package com.determination.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.Context
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
        const val ACTION_START = "com.determination.action.START_EXTERNAL_DISPLAY"
        const val ACTION_STOP = "com.determination.action.STOP_EXTERNAL_DISPLAY"

        fun startIntent(context: Context) =
            Intent(context, ExternalDisplayService::class.java).setAction(ACTION_START)
        fun stop(context: Context) {
            val previous = ExternalDisplayState.read(context)
            ExternalDisplayState.write(
                context,
                previous.copy(enabled = false, phase = "off", socketReady = false),
            )
            context.stopService(Intent(context, ExternalDisplayService::class.java))
        }
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
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
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
        val previous = ExternalDisplayState.read(this)
        ExternalDisplayState.write(this, previous.copy(enabled = true, phase = "starting", error = ""))
        presenter = ExternalDisplayPresenter(this) {
            ExternalDisplayState.write(this, it.copy(enabled = true))
        }
            .also { it.start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            ExternalDisplayState.write(
                this,
                ExternalDisplayState.read(this).copy(
                    enabled = false,
                    phase = "off",
                    socketReady = false,
                ),
            )
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        presenter?.stop()
        presenter = null
        val previous = ExternalDisplayState.read(this)
        ExternalDisplayState.write(
            this,
            previous.copy(phase = "off", socketReady = false),
        )
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
