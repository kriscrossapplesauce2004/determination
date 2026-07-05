#!/system/bin/sh
# CPU-fill smoke v2 (run as root on the device): stop SF, force a REAL
# display OFF->ON power transition (SDM no-ops a plain ON since it already
# believes the display is on — a command-mode panel left asleep ACKs frame
# DMA, fences signal, glass stays black), then run direct_hwc2_fill_test
# ~25s with the backlight forced on. Restores SF regardless of outcome.
# Eyeball question: does the panel cycle RED -> GREEN -> BLUE (~3s each)?
#
# Instruments captured for the host to pull:
#   /data/local/tmp/fill.out         test stdout/stderr
#   /data/local/tmp/fill-logcat.txt  logcat of the whole window (SDM/HWC lines)
#   /data/local/tmp/fill-dmesg.txt   dmesg with drm.debug=0x14 (kms+atomic)
#   /data/local/tmp/fill-samples.txt backlight/panel state sampled every 3s
#
# Backlight: the ACTIVE node is /sys/class/backlight/backlight (max 4095).
# panel0-backlight (max 1023) accepts writes but drives nothing.
set -u
BL=/sys/class/backlight/backlight/brightness
OLD_BL=$(cat $BL)
DRMDBG=/sys/module/drm/parameters/debug
OLD_DRMDBG=$(cat $DRMDBG 2>/dev/null || echo 0)
restore() {
    start surfaceflinger
    i=0
    until [ "$(getprop init.svc.surfaceflinger)" = "running" ]; do
        i=$((i+1)); [ $i -gt 20 ] && break; sleep 0.5
    done
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        i=0
        while [ $i -lt 20 ]; do
            [ "$(getprop init.svc.bootanim)" = "running" ] && break
            i=$((i+1)); sleep 0.5
        done
        setprop service.bootanim.exit 1
        setprop service.bootanim.progress 1
        sleep 3
        [ "$(getprop init.svc.bootanim)" = "running" ] && stop bootanim
    fi
    echo "$OLD_BL" > $BL 2>/dev/null
    echo "$OLD_DRMDBG" > $DRMDBG 2>/dev/null
    echo "SF: $(getprop init.svc.surfaceflinger) bootanim: $(getprop init.svc.bootanim)"
}
trap restore EXIT

logcat -c 2>/dev/null
echo 0x14 > $DRMDBG 2>/dev/null

stop surfaceflinger
sleep 2

( while :; do echo 2048 > $BL 2>/dev/null; sleep 1; done ) &
BLKEEP=$!
(
    : > /data/local/tmp/fill-samples.txt
    while :; do
        {
            echo "=== $(date +%T)"
            for d in /sys/class/backlight/*; do
                echo "$d brightness=$(cat $d/brightness 2>/dev/null) actual=$(cat $d/actual_brightness 2>/dev/null)"
            done
        } >> /data/local/tmp/fill-samples.txt
        sleep 3
    done
) &
SAMPLER=$!

# All three submission paths were black (2026-07-05); the current variable
# is SDM's own brightness state (FILL_BRIGHTNESS -> setDisplayBrightness).
: > /data/local/tmp/fill.out
echo "=== PHASE client+brightness $(date +%T) ===" >> /data/local/tmp/fill.out
env FILL_MODE=client FILL_VSYNC=1 FILL_BRIGHTNESS=1 \
    LD_LIBRARY_PATH=/data/local/tmp \
    timeout 15 /data/local/tmp/direct_hwc2_fill_test >> /data/local/tmp/fill.out 2>&1
echo "PHASE RC=$?" >> /data/local/tmp/fill.out
kill $BLKEEP $SAMPLER 2>/dev/null

logcat -d > /data/local/tmp/fill-logcat.txt 2>/dev/null
dmesg > /data/local/tmp/fill-dmesg.txt 2>/dev/null
cat /data/local/tmp/fill.out
