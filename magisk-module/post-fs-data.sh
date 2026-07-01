#!/system/bin/sh
# DecemberOS post-fs-data: runs early, blocking, before zygote. Only cheap,
# must-happen-before-boot work goes here; the container itself launches from
# service.sh (non-blocking, after boot).

MODDIR=${0%/*}
LOG=/data/decemberos/log
mkdir -p /data/decemberos
exec >>"$LOG/post-fs-data.log" 2>&1
mkdir -p "$LOG"
echo "--- post-fs-data $(date)"

# Boot-time desktop-off: if the phone rebooted (or panicked) while in desktop
# mode, the run/ state is stale — the suppressor loop, evgrab grabs, and guest
# compositor all died with the previous boot, but the marker files would make
# desktop-on refuse to run and could confuse anything checking the mode. A
# boot always starts in phone mode; make the state say so before anything
# reads it.
if [ -f /data/decemberos/run/desktop-mode ]; then
    echo "stale desktop-mode state from previous boot — clearing (boot = phone mode)"
fi
rm -rf /data/decemberos/run
mkdir -p /data/decemberos/run

# Hidden AOSP desktop/freeform flags — prop flips are the cheapest framework
# tweaks (spec §6); Zygisk hooks only where no flag exists.
resetprop persist.wm.debug.desktop_mode_enforce_device_restrictions false
resetprop sf.debug.show_refresh_rate_overlay 0
