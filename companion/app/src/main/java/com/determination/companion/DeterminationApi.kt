package com.determination.companion

/** Stable Android-facing names. Native protocol details stay private. */
object DeterminationApi {
    const val ACTION_STATUS = "com.determination.action.STATUS"
    const val ACTION_CAPABILITIES = "com.determination.action.CAPABILITIES"
    const val ACTION_METRICS = "com.determination.action.METRICS"
    const val ACTION_REQUEST_MODE = "com.determination.action.REQUEST_MODE"
    const val ACTION_BIND_CONTROL = "com.determination.action.BIND_CONTROL"

    const val EXTRA_MODE = "com.determination.extra.MODE"
    const val EXTRA_JSON = "com.determination.extra.JSON"
    const val EXTRA_STATUS = "com.determination.extra.STATUS"

    const val MODE_PHONE = "phone"
    const val MODE_DESKTOP = "desktop"

    const val RESULT_UNAVAILABLE = ZygiskBridge.STATUS_UNAVAILABLE
    const val RESULT_INVALID = ZygiskBridge.STATUS_INVALID

    fun validMode(value: String?): Boolean = value == MODE_PHONE || value == MODE_DESKTOP
}
