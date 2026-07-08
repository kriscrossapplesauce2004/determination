package com.determination.companion

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private val io = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())

    private lateinit var statusText: TextView
    private lateinit var rootText: TextView
    private lateinit var enterBtn: Button
    private lateinit var exitBtn: Button
    private lateinit var refreshBtn: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        rootText = findViewById(R.id.rootText)
        enterBtn = findViewById(R.id.enterBtn)
        exitBtn = findViewById(R.id.exitBtn)
        refreshBtn = findViewById(R.id.refreshBtn)

        enterBtn.setOnClickListener { confirmEnter() }
        exitBtn.setOnClickListener { doExit() }
        refreshBtn.setOnClickListener { refresh() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun setBusy(busy: Boolean) {
        enterBtn.isEnabled = !busy
        exitBtn.isEnabled = !busy
        refreshBtn.isEnabled = !busy
    }

    private fun refresh() {
        statusText.text = getString(R.string.checking)
        setBusy(true)
        io.execute {
            val hasRoot = Root.hasRoot()
            val s = if (hasRoot) Root.status() else emptyMap()
            ui.post {
                setBusy(false)
                if (!hasRoot) {
                    rootText.text = getString(R.string.no_root)
                    statusText.text = getString(R.string.no_root_hint)
                    enterBtn.isEnabled = false
                    exitBtn.isEnabled = false
                    return@post
                }
                rootText.text = getString(R.string.root_ok)
                val mode = s["mode"] ?: "?"
                val guest = s["guest"] ?: "?"
                val installed = s["installed"] == "yes"
                statusText.text = buildString {
                    append("Mode:    ").append(mode.uppercase()).append('\n')
                    append("Guest:   ").append(guest).append('\n')
                    append("SF:      ").append(s["sf"] ?: "?").append('\n')
                    append("Agent:   ").append(s["agent"] ?: "?").append('\n')
                    append("Kernel:  ").append(s["kernel"] ?: "?").append('\n')
                    if (!installed) append('\n').append(getString(R.string.not_installed))
                }
                enterBtn.isEnabled = installed && mode == "phone"
                exitBtn.isEnabled = installed && mode == "desktop"
            }
        }
    }

    private fun confirmEnter() {
        AlertDialog.Builder(this)
            .setTitle(R.string.enter_title)
            .setMessage(R.string.enter_body)
            .setPositiveButton(R.string.enter_go) { _, _ -> doEnter() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun doEnter() {
        setBusy(true)
        statusText.text = getString(R.string.entering)
        io.execute {
            val r = Root.enterDesktop()
            // The Android UI (this app) is handed off to the guest a moment
            // after SF stops; we may never run the ui.post below. That's fine.
            ui.post {
                setBusy(false)
                if (!r.ok) {
                    statusText.text = getString(R.string.enter_failed, r.err.ifBlank { r.out })
                }
            }
        }
    }

    private fun doExit() {
        setBusy(true)
        statusText.text = getString(R.string.exiting)
        io.execute {
            val r = Root.exitDesktop()
            ui.post {
                setBusy(false)
                if (!r.ok) statusText.text = getString(R.string.exit_failed, r.err.ifBlank { r.out })
                else refresh()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        io.shutdownNow()
    }
}
