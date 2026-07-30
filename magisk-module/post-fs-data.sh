#!/system/bin/sh
# Determination post-fs-data: runs early, blocking, before zygote. Only cheap,
# must-happen-before-boot work goes here; the container itself launches from
# service.sh (non-blocking, after boot).

MODDIR=${0%/*}
LOG=/data/determination/log
mkdir -p /data/determination
mkdir -p "$LOG"
exec >>"$LOG/post-fs-data.log" 2>&1
echo "--- post-fs-data $(date)"

# Boot-time desktop-off: if the phone rebooted (or panicked) while in desktop
# mode, the run/ state is stale --- the suppressor loop, evgrab grabs, and guest
# compositor all died with the previous boot, but the marker files would make
# desktop-on refuse to run and could confuse anything checking the mode. A
# boot always starts in phone mode; make the state say so before anything
# reads it.
if [ -f /data/determination/run/desktop-mode ]; then
    echo "stale desktop-mode state from previous boot --- clearing (boot = phone mode)"
fi
rm -rf /data/determination/run
mkdir -p /data/determination/run

# A Linux-first request is intent only at this early boot point. service.sh
# applies it after boot dependencies exist; an incomplete prior attempt is
# forced back to PHONE before any display ownership action can run.
if [ -r /data/determination/state/boot-profile ]; then
    result=$(sed -n 's/^result=//p' /data/determination/state/boot-profile | tail -n 1)
    desired=$(sed -n 's/^desired=//p' /data/determination/state/boot-profile | tail -n 1)
    if [ "$desired" = linux-first ] && [ "$result" = entering ]; then
        sed 's/^desired=.*/desired=phone/; s/^result=.*/result=recovered-before-boot/' \
            /data/determination/state/boot-profile > /data/determination/state/boot-profile.new &&
            mv -f /data/determination/state/boot-profile.new /data/determination/state/boot-profile
        echo "incomplete Linux-first attempt recovered to phone"
    fi
fi

# NO framework prop tweaks here. v0.1.0 set
# persist.wm.debug.desktop_mode_enforce_device_restrictions, which crash-looped
# SystemUI on crDroid 12.10/A16 badly enough to block the lockscreen (2026-07-02).
# The spec-§6 desktop-mode flags need per-flag testing over adb (where they can
# be reverted) before any of them ship in post-fs-data again.
