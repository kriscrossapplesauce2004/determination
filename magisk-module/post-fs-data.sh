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

# Hidden AOSP desktop/freeform flags — prop flips are the cheapest framework
# tweaks (spec §6); Zygisk hooks only where no flag exists.
resetprop persist.wm.debug.desktop_mode_enforce_device_restrictions false
resetprop sf.debug.show_refresh_rate_overlay 0
