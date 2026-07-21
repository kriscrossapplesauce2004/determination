package com.determination.companion

import android.content.Context
import android.content.Intent

data class ExternalDisplaySnapshot(
    val enabled: Boolean = false,
    val phase: String = "off",
    val displayName: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val refreshRate: Float = 0f,
    val socketReady: Boolean = false,
    val error: String = "",
) {
    val displayConnected: Boolean get() = width > 0 && height > 0
}

/** Device-protected state shared by the boot-aware presenter and normal UI. */
object ExternalDisplayState {
    const val ACTION_CHANGED = "com.determination.action.EXTERNAL_DISPLAY_CHANGED"
    private const val STORE = "det-external-display"

    fun read(context: Context): ExternalDisplaySnapshot {
        val prefs = context.createDeviceProtectedStorageContext()
            .getSharedPreferences(STORE, Context.MODE_PRIVATE)
        return ExternalDisplaySnapshot(
            enabled = prefs.getBoolean("enabled", false),
            phase = prefs.getString("phase", "off") ?: "off",
            displayName = prefs.getString("display_name", "") ?: "",
            width = prefs.getInt("width", 0),
            height = prefs.getInt("height", 0),
            refreshRate = prefs.getFloat("refresh_rate", 0f),
            socketReady = prefs.getBoolean("socket_ready", false),
            error = prefs.getString("error", "") ?: "",
        )
    }

    fun write(context: Context, value: ExternalDisplaySnapshot) {
        context.createDeviceProtectedStorageContext()
            .getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .edit()
            .putBoolean("enabled", value.enabled)
            .putString("phase", value.phase)
            .putString("display_name", value.displayName)
            .putInt("width", value.width)
            .putInt("height", value.height)
            .putFloat("refresh_rate", value.refreshRate)
            .putBoolean("socket_ready", value.socketReady)
            .putString("error", value.error)
            .apply()
        context.sendBroadcast(Intent(ACTION_CHANGED).setPackage(context.packageName))
    }
}
