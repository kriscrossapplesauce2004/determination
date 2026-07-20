package com.determination.companion

import android.app.Service
import android.content.Intent
import android.os.IBinder

/** Same-signature typed API; detd remains the authoritative service. */
class DeterminationControlService : Service() {
    private val binder = object : IDeterminationControl.Stub() {
        override fun getStatusJson(): String =
            readJson(ZygiskBridge.OP_STATUS)

        override fun getCapabilitiesJson(): String =
            readJson(ZygiskBridge.OP_CAPABILITIES)

        override fun getMetricsJson(): String =
            readJson(ZygiskBridge.OP_METRICS)

        override fun requestMode(target: String?): Int {
            if (!DeterminationApi.validMode(target)) return ZygiskBridge.STATUS_INVALID
            return ZygiskBridge.mode(target!!)?.status ?: ZygiskBridge.STATUS_UNAVAILABLE
        }

        private fun readJson(operation: Int): String {
            val response = ZygiskBridge.request(operation, deadlineMs = 5_000)
            return if (response?.ok == true) response.payload else ""
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
