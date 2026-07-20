package com.determination.companion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Explicit, read-only ordered-broadcast API for ordinary apps. It talks only
 * to the same-UID Zygisk/detd bridge and never opens a root shell fallback.
 */
class DeterminationStatusReceiver : BroadcastReceiver() {
    companion object {
        private val requestInFlight = AtomicBoolean(false)
    }

    override fun onReceive(context: Context, intent: Intent) {
        val operation = when (intent.action) {
            DeterminationApi.ACTION_STATUS -> ZygiskBridge.OP_STATUS
            DeterminationApi.ACTION_CAPABILITIES -> ZygiskBridge.OP_CAPABILITIES
            DeterminationApi.ACTION_METRICS -> ZygiskBridge.OP_METRICS
            else -> {
                resultCode = DeterminationApi.RESULT_INVALID
                return
            }
        }
        if (!requestInFlight.compareAndSet(false, true)) {
            resultCode = ZygiskBridge.STATUS_BUSY
            return
        }
        val pending = goAsync()
        thread(name = "det-api-read", isDaemon = true) {
            try {
                val response = ZygiskBridge.request(operation, deadlineMs = 5_000)
                pending.setResultCode(
                    response?.status ?: DeterminationApi.RESULT_UNAVAILABLE,
                )
                pending.setResultExtras(Bundle().apply {
                    putInt(
                        DeterminationApi.EXTRA_STATUS,
                        response?.status ?: DeterminationApi.RESULT_UNAVAILABLE,
                    )
                    putString(DeterminationApi.EXTRA_JSON, response?.payload ?: "")
                })
            } finally {
                requestInFlight.set(false)
                pending.finish()
            }
        }
    }
}
