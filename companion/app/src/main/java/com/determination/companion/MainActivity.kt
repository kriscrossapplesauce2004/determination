package com.determination.companion

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.color.DynamicColors
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private val io = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())

    private lateinit var statusText: TextView
    private lateinit var rootText: TextView
    private lateinit var enterBtn: Button
    private lateinit var exitBtn: Button
    private lateinit var recoverBtn: Button
    private lateinit var restartGuestBtn: Button
    private lateinit var rebootBtn: Button
    private lateinit var powerBtn: Button
    private lateinit var logBtn: Button
    private lateinit var refreshBtn: Button

    private val logs = arrayOf("compositor.log", "toggle.log", "hostagent.log", "service.log")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Material You 3: apply the wallpaper-derived dynamic palette (Android 12+).
        DynamicColors.applyToActivityIfAvailable(this)
        // Edge-to-edge: draw behind the transparent system bars, then inset the
        // scrolling column so content never hides under status/nav bars.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContentView(R.layout.activity_main)

        val rootColumn = findViewById<LinearLayout>(R.id.rootColumn)
        val basePadTop = rootColumn.paddingTop
        val basePadBottom = rootColumn.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(rootColumn) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.updatePadding(top = basePadTop + bars.top, bottom = basePadBottom + bars.bottom)
            insets
        }

        statusText = findViewById(R.id.statusText)
        rootText = findViewById(R.id.rootText)
        enterBtn = findViewById(R.id.enterBtn)
        exitBtn = findViewById(R.id.exitBtn)
        recoverBtn = findViewById(R.id.recoverBtn)
        restartGuestBtn = findViewById(R.id.restartGuestBtn)
        rebootBtn = findViewById(R.id.rebootBtn)
        powerBtn = findViewById(R.id.powerBtn)
        logBtn = findViewById(R.id.logBtn)
        refreshBtn = findViewById(R.id.refreshBtn)

        enterBtn.setOnClickListener { confirmEnter() }
        exitBtn.setOnClickListener { runAction(R.string.exiting) { Root.exitDesktop() } }
        recoverBtn.setOnClickListener { runAction(R.string.recovering) { Root.recoverDesktop() } }
        restartGuestBtn.setOnClickListener { runAction(R.string.restarting_guest) { Root.restartGuest() } }
        rebootBtn.setOnClickListener {
            confirmPower(R.string.confirm_reboot_title) { runAction(R.string.working) { Root.rebootPhone() } }
        }
        powerBtn.setOnClickListener {
            confirmPower(R.string.confirm_poweroff_title) { runAction(R.string.working) { Root.powerOff() } }
        }
        logBtn.setOnClickListener { pickLog() }
        refreshBtn.setOnClickListener { refresh() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun setBusy(busy: Boolean) {
        for (b in listOf(enterBtn, exitBtn, recoverBtn, restartGuestBtn, rebootBtn, powerBtn, logBtn, refreshBtn)) {
            b.isEnabled = !busy
        }
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
                    listOf(enterBtn, exitBtn, recoverBtn, restartGuestBtn, rebootBtn, powerBtn, logBtn).forEach { it.isEnabled = false }
                    return@post
                }
                rootText.text = getString(R.string.root_ok)
                val mode = s["mode"] ?: "?"
                val installed = s["installed"] == "yes"
                val desktop = mode == "desktop"
                val batt = s["batt"]?.takeIf { it.isNotBlank() } ?: "?"
                statusText.text = buildString {
                    append("Mode     ").append(mode.uppercase()).append('\n')
                    append("Guest    ").append(s["guest"] ?: "?")
                    (s["ip"]?.takeIf { it.isNotBlank() })?.let { append("  (").append(it).append(')') }
                    append('\n')
                    append("SF       ").append(s["sf"] ?: "?").append('\n')
                    append("Agent    ").append(s["agent"] ?: "?").append('\n')
                    append("Battery  ").append(batt).append("%  ")
                        .append(s["battmv"] ?: "?").append("mV  ").append(s["battstat"] ?: "").append('\n')
                    append("Kernel   ").append(s["kernel"] ?: "?")
                    if (!installed) append("\n\n").append(getString(R.string.not_installed))
                }
                enterBtn.isEnabled = installed && !desktop
                restartGuestBtn.isEnabled = installed && !desktop
                exitBtn.isEnabled = installed && desktop
                recoverBtn.isEnabled = installed && desktop
                // reboot/power/log always available with root
            }
        }
    }

    private fun confirmEnter() {
        AlertDialog.Builder(this)
            .setTitle(R.string.enter_title)
            .setMessage(R.string.enter_body)
            .setPositiveButton(R.string.enter_go) { _, _ -> runAction(R.string.entering) { Root.enterDesktop() } }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun confirmPower(titleRes: Int, go: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(titleRes)
            .setMessage(R.string.confirm_power_body)
            .setPositiveButton(android.R.string.ok) { _, _ -> go() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** Run a Root action off the UI thread, show progress, refresh after. */
    private fun runAction(progressRes: Int, action: () -> Root.Result) {
        setBusy(true)
        statusText.text = getString(progressRes)
        io.execute {
            val r = action()
            ui.post {
                setBusy(false)
                if (!r.ok) statusText.text = getString(R.string.action_failed, r.err.ifBlank { r.out })
                else refresh()
            }
        }
    }

    private fun pickLog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.log_pick_title)
            .setItems(logs) { _, which -> showLog(logs[which]) }
            .setNegativeButton(R.string.close, null)
            .show()
    }

    private fun showLog(name: String) {
        setBusy(true)
        io.execute {
            val logText = Root.tailLog(name)
            ui.post {
                setBusy(false)
                val tv = TextView(this).apply {
                    setTextIsSelectable(true)
                    typeface = android.graphics.Typeface.MONOSPACE
                    textSize = 11f
                    setPadding(40, 24, 40, 24)
                    text = logText
                }
                val scroll = android.widget.ScrollView(this).apply { addView(tv) }
                AlertDialog.Builder(this)
                    .setTitle(name)
                    .setView(scroll)
                    .setPositiveButton(R.string.close, null)
                    .show()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        io.shutdownNow()
    }
}
