package com.determination.companion

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.widget.Toast
import kotlin.concurrent.thread

/** Confirmation trampoline for root-backed launcher shortcuts. */
class DesktopShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.action != ACTION_ENTER) {
            finish()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.enter_title)
            .setMessage(R.string.enter_body)
            .setNegativeButton(android.R.string.cancel) { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .setPositiveButton(R.string.enter_go) { _, _ ->
                thread(name = "det-shortcut-enter", isDaemon = true) {
                    val result = Root.enterDesktop()
                    if (!result.ok) runOnUiThread {
                        Toast.makeText(
                            this,
                            getString(R.string.enter_failed, result.err.ifBlank { result.out }),
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                    runOnUiThread { finish() }
                }
            }
            .show()
    }

    companion object {
        const val ACTION_ENTER = "com.determination.companion.action.ENTER_DESKTOP"
    }
}
