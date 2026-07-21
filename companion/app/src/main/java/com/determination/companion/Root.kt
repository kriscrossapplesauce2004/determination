package com.determination.companion

import java.io.BufferedReader
import java.io.BufferedWriter
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Thin wrapper around Magisk `su`. Commands run through ONE persistent root
 * shell (a single su grant per app session) instead of a fresh `su -c` per
 * call — spawning su every 5s poll made Magisk toast "granted superuser
 * rights" endlessly. Determination's on-device tree lives at [DET].
 */
object Root {
    const val DET = "/data/determination"
    private const val BIN = "$DET/bin"
    private const val LXC = "$DET/lxc/bin"
    private const val MODDIR = "/data/adb/modules/determination"

    data class Result(val ok: Boolean, val out: String, val err: String)

    private const val MARK = "__DET_DONE__"
    private var shell: Process? = null
    private var stdin: BufferedWriter? = null
    private var stdout: BufferedReader? = null
    private var stderr: BufferedReader? = null
    private val reader = Executors.newCachedThreadPool()

    @Synchronized
    private fun ensureShell(): Boolean {
        shell?.let { if (it.isAlive) return true }
        return try {
            val p = ProcessBuilder("su").redirectErrorStream(false).start()
            shell = p
            stdin = p.outputStream.bufferedWriter()
            stdout = p.inputStream.bufferedReader()
            stderr = p.errorStream.bufferedReader()
            true
        } catch (e: Exception) {
            shell = null
            false
        }
    }

    @Synchronized
    private fun killShell() {
        shell?.destroyForcibly()
        shell = null
    }

    /** Run a command string in the persistent root shell. Blocking. */
    @Synchronized
    fun run(cmd: String, timeoutSec: Long = 15): Result {
        if (!ensureShell()) return Result(false, "", "su failed (no root?)")
        return try {
            stdin!!.apply {
                // Subshell so `exit`/`set -e` in cmd can't kill our shell.
                write("($cmd)\n")
                write("echo $MARK$?; echo $MARK >&2\n")
                flush()
            }
            val outF = reader.submit<String> { readUntilMark(stdout!!) }
            val errF = reader.submit<String> { readUntilMark(stderr!!) }
            val outRaw = outF.get(timeoutSec, TimeUnit.SECONDS)
            val err = errF.get(2, TimeUnit.SECONDS)
            val nl = outRaw.lastIndexOf('\n')
            val rcLine = outRaw.substring(nl + 1)
            val out = if (nl >= 0) outRaw.substring(0, nl) else ""
            Result(rcLine == "0", out.trim(), err.trim())
        } catch (e: TimeoutException) {
            killShell()
            Result(false, "", "timed out after ${timeoutSec}s")
        } catch (e: Exception) {
            killShell()
            Result(false, "", e.message ?: "su failed (no root?)")
        }
    }

    /** Read lines until the marker; return text before it (marker line carries rc on stdout). */
    private fun readUntilMark(r: BufferedReader): String {
        val sb = StringBuilder()
        while (true) {
            val line = r.readLine() ?: throw RuntimeException("root shell died")
            if (line.startsWith(MARK)) {
                sb.append(line.removePrefix(MARK))
                return sb.toString()
            }
            sb.append(line).append('\n')
        }
    }

    /** True if `su` is present and grants uid 0. */
    fun hasRoot(): Boolean = run("id -u", 8).let { it.ok && it.out.trim() == "0" }

    /** Whether the on-device Determination tree is installed. */
    fun isInstalled(): Boolean = run("[ -x $BIN/desktop-on ] && echo yes", 8).out.contains("yes")

    /** One su round-trip that returns parseable key=value status lines. */
    /*
     * Do not use the app-process Zygisk bridge here. A newly installed APK can
     * run before the matching module library is loaded by a reboot, and mixing
     * protocol/library generations has caused an uncatchable native SIGBUS.
     * The persistent root shell is slower only on its first call and works
     * across module upgrades without coupling the launcher to injected code.
     */
    fun status(): Map<String, String> = legacyStatus()

    private fun legacyStatus(): Map<String, String> {
        val script = """
            echo "uid=${'$'}(id -u)"
            echo "kernel=${'$'}(uname -r)"
            echo "sf=${'$'}(getprop init.svc.surfaceflinger)"
            [ -f $DET/run/desktop-mode ] && echo "mode=desktop" || echo "mode=phone"
            $LXC/lxc-info -P $DET -n guest 2>/dev/null | grep -q RUNNING && echo "guest=running" || echo "guest=stopped"
            [ -e $DET/run/hostagent.pid ] && echo "agent=up" || echo "agent=down"
            echo "installed=${'$'}([ -x $BIN/desktop-on ] && echo yes || echo no)"
            echo "ip=${'$'}($LXC/lxc-info -P $DET -n guest 2>/dev/null | awk '/IP:/{print ${'$'}2; exit}')"
            gauge=${'$'}(sed -n 's/^DET_BATTERY_GAUGE=//p' $DET/etc/device.conf 2>/dev/null | tail -n 1)
            [ -n "${'$'}gauge" ] || gauge=battery
            echo "batt=${'$'}(cat /sys/class/power_supply/${'$'}gauge/capacity 2>/dev/null)"
            echo "battmv=${'$'}(( ${'$'}(cat /sys/class/power_supply/${'$'}gauge/voltage_now 2>/dev/null || echo 0) / 1000 ))"
            echo "battstat=${'$'}(cat /sys/class/power_supply/battery/status 2>/dev/null)"
            up=${'$'}(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
            echo "uptime=${'$'}((up / 3600))h ${'$'}(( (up % 3600) / 60 ))m"
            echo "datafree=${'$'}(df -h /data 2>/dev/null | awk 'NR==2{print ${'$'}4}')"
        """.trimIndent()
        val r = run(script, 12)
        return parseKv(r.out)
    }

    private fun parseKv(text: String): Map<String, String> {
        val m = HashMap<String, String>()
        text.lineSequence().forEach { line ->
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
    fun enterDesktop(): Result {
        return run(
            "$BIN/guest-start >/dev/null 2>&1; " +
                "setsid sh -c 'nohup $BIN/desktop-on >/dev/null 2>&1' >/dev/null 2>&1 &",
            20,
        )
    }

    /** Return to phone mode (restarts SurfaceFlinger). */
    fun exitDesktop(): Result {
        return run("$BIN/desktop-off", 30)
    }

    /** Copy an Android share-sheet staging file into Linux, guest running or not. */
    fun importToGuest(sourcePath: String, displayName: String): Result {
        val safeName = displayName
            .filter { it.code >= 32 && it !in "/\\" }
            .take(120)
            .ifBlank { "Shared file" }
        val inbox = "$DET/guest/home/melissa/Downloads/From Android"
        val destination = "$inbox/$safeName"
        return run(
            "install -d -m 0755 -o 1000 -g 1000 ${shellQuote(inbox)}; " +
                "cp -f ${shellQuote(sourcePath)} ${shellQuote(destination)}; " +
                "chown 1000:1000 ${shellQuote(destination)}; " +
                "chmod 0644 ${shellQuote(destination)}",
            30,
        )
    }

    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    /**
     * Recover a wedged desktop session without a full toggle: kill phoc; the
     * desktop-on supervisor relaunches the whole stack (compositor + phosh +
     * grabs) within ~10s. The go-to fix when the panel blanks or freezes.
     */
    fun recoverDesktop(): Result =
        run("$LXC/lxc-attach -P $DET -n guest -- /usr/bin/pkill -TERM phoc", 15)

    /** Stop the guest container (battery saver — it idles at ~0 but holds RAM + wakeups). */
    fun stopGuest(): Result = run("$LXC/lxc-stop -P $DET -n guest -t 10", 30)

    /**
     * Persist the "stop guest when leaving desktop mode" flag where desktop-off
     * reads it, so exits triggered from inside the desktop honor it too.
     */
    fun setStopGuestOnExitFlag(on: Boolean): Result =
        if (on) run("mkdir -p $DET/etc && touch $DET/etc/stop-guest-on-exit", 8)
        else run("rm -f $DET/etc/stop-guest-on-exit", 8)

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
    fun tailLog(name: String, lines: Int = 120): String {
        val safe = name.filter { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }
        val r = run("tail -n $lines $DET/log/$safe 2>/dev/null", 10)
        return if (r.out.isBlank()) "(empty or not found: $safe)" else r.out
    }

    // ── Installer / updater ────────────────────────────────────────────────

    /**
     * Installed-component inventory in one su round-trip. Keys:
     * kernel, det_kernel (yes/no — binderfs marker), module_ver, module_code,
     * guest (debian version or empty), slot, boot_part.
     */
    fun inventory(): Map<String, String> {
        val script = """
            echo "kernel=${'$'}(uname -r)"
            zcat /proc/config.gz 2>/dev/null | grep -q ANDROID_BINDERFS=y && echo "det_kernel=yes" || echo "det_kernel=no"
            echo "module_ver=${'$'}(grep '^version=' $MODDIR/module.prop 2>/dev/null | cut -d= -f2)"
            echo "module_code=${'$'}(grep '^versionCode=' $MODDIR/module.prop 2>/dev/null | cut -d= -f2)"
            [ -f $MODDIR/disable ] && echo "module_state=disabled" || echo "module_state=enabled"
            echo "guest=${'$'}(cat $DET/guest/etc/debian_version 2>/dev/null)"
            echo "slot=${'$'}(getprop ro.boot.slot_suffix)"
            echo "boot_part=${'$'}(ls -l /dev/block/bootdevice/by-name/boot${'$'}(getprop ro.boot.slot_suffix) 2>/dev/null | awk '{print ${'$'}NF}')"
            echo "toolkit=${'$'}([ -x $BIN/desktop-on ] && echo yes || echo no)"
        """.trimIndent()
        return parseKv(run(script, 12).out)
    }

    /** Candidate artifacts for the updater, newest first: zips, boot images, APKs. */
    fun findArtifacts(): List<String> {
        val r = run(
            "ls -1t /sdcard/Download/determination-magisk-*.zip " +
                "/sdcard/Download/decemberos-magisk-*.zip " +
                "/sdcard/Download/boot*.img /sdcard/Download/determination*.img " +
                "/sdcard/Download/*companion*.apk /sdcard/Download/app-*.apk " +
                "/data/local/tmp/determination-magisk-*.zip /data/local/tmp/boot*.img " +
                "/data/local/tmp/*companion*.apk /data/local/tmp/app-*.apk 2>/dev/null",
            10
        )
        return r.out.lineSequence().map { it.trim() }.filter { it.startsWith("/") }.toList()
    }

    /** Install/upgrade the Magisk module from a zip. Takes effect on reboot. */
    fun installModuleZip(path: String): Result =
        run("magisk --install-module '${sanitizePath(path)}'", 120)

    /**
     * Flash a boot image to the CURRENT slot. Refuses anything that doesn't
     * carry the ANDROID! magic. The UI double-confirms before calling this.
     */
    fun flashBootImage(path: String): Result {
        val p = sanitizePath(path)
        val script = """
            set -e
            [ "${'$'}(dd if='$p' bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || { echo "not a boot image (no ANDROID! magic)"; exit 1; }
            slot=${'$'}(getprop ro.boot.slot_suffix)
            part=/dev/block/bootdevice/by-name/boot${'$'}slot
            [ -e "${'$'}part" ] || { echo "boot partition not found: ${'$'}part"; exit 1; }
            dd if='$p' of="${'$'}part" bs=1048576
            sync
            echo "flashed to boot${'$'}slot"
        """.trimIndent()
        return run(script, 60)
    }

    /** Sideload an APK update of this app (root pm install; survives self-update). */
    fun installApk(path: String): Result {
        val p = sanitizePath(path)
        return run("cp '$p' /data/local/tmp/det-companion-update.apk && pm install -r /data/local/tmp/det-companion-update.apk", 60)
    }

    private fun sanitizePath(path: String): String =
        path.filter { it.isLetterOrDigit() || it in "/._-" }

    // ── Guest software catalog ─────────────────────────────────────────────

    fun guestRunning(): Boolean =
        run("$LXC/lxc-info -P $DET -n guest 2>/dev/null | grep -q RUNNING && echo yes", 8)
            .out.contains("yes")

    /** Compositor pref + guest state in one su round-trip (Software tab load). */
    fun sessionInfo(): Map<String, String> = parseKv(
        run(
            "echo \"compositor=${'$'}(cat $DET/etc/compositor 2>/dev/null)\"; " +
                "$LXC/lxc-info -P $DET -n guest 2>/dev/null | grep -q RUNNING " +
                "&& echo guestup=yes || echo guestup=no",
            10
        ).out
    )

    /** dpkg status for many packages: ONE lxc-attach for the whole list. */
    fun dpkgStatus(pkgs: List<String>): Map<String, String> {
        if (pkgs.isEmpty()) return emptyMap()
        val safe = pkgs.map { it.filter { c -> c.isLetterOrDigit() || c in ".+-" } }
        val r = run(
            "$LXC/lxc-attach -P $DET -n guest -- dpkg-query -W " +
                "-f '\${Package}=\${db:Status-Status}\\n' ${safe.joinToString(" ")} 2>/dev/null",
            30
        )
        val states = parseKv(r.out)
        return safe.associateWith { if (states[it] == "installed") "installed" else "absent" }
    }

    /** apt-get install inside the guest. Long timeout — packages can be big. */
    fun aptInstall(pkg: String): Result {
        val p = pkg.filter { it.isLetterOrDigit() || it in ".+-" }
        return run(
            "$LXC/lxc-attach -P $DET -n guest -- /bin/sh -c " +
                "'export DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin; " +
                "apt-get update -qq 2>/dev/null; apt-get install -y $p' 2>&1 | tail -5",
            600
        )
    }

    fun aptRemove(pkg: String): Result {
        val p = pkg.filter { it.isLetterOrDigit() || it in ".+-" }
        return run(
            "$LXC/lxc-attach -P $DET -n guest -- /bin/sh -c " +
                "'export DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin; " +
                "apt-get remove -y $p' 2>&1 | tail -5",
            300
        )
    }

    /**
     * Session/compositor preference. Only phoc/phosh is wired into desktop-on
     * today; the choice is persisted at $DET/etc/compositor for the session
     * launcher to honor as alternatives land.
     */
    fun getCompositor(): String =
        run("cat $DET/etc/compositor 2>/dev/null", 8).out.trim().ifBlank { "phosh" }

    fun setCompositor(id: String): Result {
        val safe = id.filter { it.isLetterOrDigit() || it == '-' }
        return run("mkdir -p $DET/etc && echo '$safe' > $DET/etc/compositor", 8)
    }

    fun externalPresenterSmoke(): Result = run("$BIN/external-presenter smoke", 45)

    fun externalPresenterPlasma(): Result = run("$BIN/external-presenter plasma", 30)
}
