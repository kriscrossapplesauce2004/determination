package com.determination.companion

import java.io.BufferedReader
import java.util.concurrent.TimeUnit

/**
 * Thin wrapper around Magisk `su`. The app never holds root itself — it shells
 * out to `su -c` for each action, exactly like `det shell` does over adb.
 * Determination's on-device tree lives at [DET]; see toggle/ for the scripts.
 */
object Root {
    const val DET = "/data/determination"
    private const val BIN = "$DET/bin"
    private const val LXC = "$DET/lxc/bin"

    data class Result(val ok: Boolean, val out: String, val err: String)

    /** Run a command string through `su -c`, capturing output. Blocking. */
    fun run(cmd: String, timeoutSec: Long = 15): Result {
        return try {
            val p = ProcessBuilder("su", "-c", cmd).redirectErrorStream(false).start()
            val out = p.inputStream.bufferedReader().use(BufferedReader::readText)
            val err = p.errorStream.bufferedReader().use(BufferedReader::readText)
            val finished = p.waitFor(timeoutSec, TimeUnit.SECONDS)
            if (!finished) {
                p.destroyForcibly()
                Result(false, out, "timed out after ${timeoutSec}s")
            } else {
                Result(p.exitValue() == 0, out.trim(), err.trim())
            }
        } catch (e: Exception) {
            Result(false, "", e.message ?: "su failed (no root?)")
        }
    }

    /** True if `su` is present and grants uid 0. */
    fun hasRoot(): Boolean = run("id -u", 8).let { it.ok && it.out.trim() == "0" }

    /** Whether the on-device Determination tree is installed. */
    fun isInstalled(): Boolean = run("[ -x $BIN/desktop-on ] && echo yes", 8).out.contains("yes")

    /** One su round-trip that returns parseable key=value status lines. */
    fun status(): Map<String, String> {
        val script = """
            echo "kernel=${'$'}(uname -r)"
            echo "sf=${'$'}(getprop init.svc.surfaceflinger)"
            [ -f $DET/run/desktop-mode ] && echo "mode=desktop" || echo "mode=phone"
            $LXC/lxc-info -P $DET -n guest 2>/dev/null | grep -q RUNNING && echo "guest=running" || echo "guest=stopped"
            [ -e $DET/run/hostagent.pid ] && echo "agent=up" || echo "agent=down"
            echo "installed=${'$'}([ -x $BIN/desktop-on ] && echo yes || echo no)"
            echo "ip=${'$'}($LXC/lxc-info -P $DET -n guest 2>/dev/null | awk '/IP:/{print ${'$'}2; exit}')"
            echo "batt=${'$'}(cat /sys/class/power_supply/bms/capacity 2>/dev/null)"
            echo "battmv=${'$'}(( ${'$'}(cat /sys/class/power_supply/bms/voltage_now 2>/dev/null || echo 0) / 1000 ))"
            echo "battstat=${'$'}(cat /sys/class/power_supply/battery/status 2>/dev/null)"
        """.trimIndent()
        val r = run(script, 12)
        val m = HashMap<String, String>()
        r.out.lineSequence().forEach { line ->
            val i = line.indexOf('=')
            if (i > 0) m[line.substring(0, i)] = line.substring(i + 1).trim()
        }
        return m
    }

    /**
     * Enter desktop mode. Ensures the guest is up, then launches desktop-on
     * DETACHED (setsid + nohup) so it survives this app being killed when
     * SurfaceFlinger stops and the Android UI disappears a moment later.
     */
    fun enterDesktop(): Result = run(
        "$BIN/guest-start >/dev/null 2>&1; " +
            "setsid sh -c 'nohup $BIN/desktop-on >/dev/null 2>&1' >/dev/null 2>&1 &",
        20
    )

    /** Return to phone mode (restarts SurfaceFlinger). */
    fun exitDesktop(): Result = run("$BIN/desktop-off", 30)

    /**
     * Recover a wedged desktop session without a full toggle: kill phoc; the
     * desktop-on supervisor relaunches the whole stack (compositor + phosh +
     * grabs) within ~10s. The go-to fix when the panel blanks or freezes.
     */
    fun recoverDesktop(): Result =
        run("$LXC/lxc-attach -P $DET -n guest -- /usr/bin/pkill -TERM phoc", 15)

    /** Stop + cold-start the guest container (guest-start is idempotent). */
    fun restartGuest(): Result = run(
        "$LXC/lxc-stop -P $DET -n guest -t 10 2>/dev/null; $BIN/guest-start", 40
    )

    /** Whole-phone power actions (best-effort clean teardown first). */
    fun rebootPhone(): Result =
        run("$BIN/desktop-off 2>/dev/null; svc power reboot || reboot", 20)

    fun powerOff(): Result =
        run("$BIN/desktop-off 2>/dev/null; svc power shutdown || reboot -p", 20)

    /** Tail one of the on-device logs for the in-app viewer. */
    fun tailLog(name: String, lines: Int = 60): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }
        val r = run("tail -n $lines $DET/log/$safe 2>/dev/null", 10)
        return if (r.out.isBlank()) "(empty or not found: $safe)" else r.out
    }
}
