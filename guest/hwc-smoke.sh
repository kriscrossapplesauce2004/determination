#!/system/bin/sh
# Atomic §3 gate test: stop SF, run test_hwcomposer INSIDE the guest via
# libhybris, restore SF regardless of outcome. Forces the panel backlight
# on during the run — stopping SF zeroes it, which made renders invisible.
set -u
# ACTIVE node is backlight/ (max 4095); panel0-backlight is inert (2026-07-05).
BL=/sys/class/backlight/backlight/brightness
OLD_BL=$(cat $BL)
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
    echo "SF: $(getprop init.svc.surfaceflinger) bootanim: $(getprop init.svc.bootanim)"
}
trap restore EXIT
stop surfaceflinger
sleep 2
(
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        echo 2048 > $BL 2>/dev/null
        sleep 2
    done
) &
BLKEEP=$!
/data/decemberos/lxc/bin/lxc-attach -P /data/decemberos -n guest -- /bin/sh -c '
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export LD_LIBRARY_PATH=/usr/local/lib
    export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
    export EGL_PLATFORM=hwcomposer HYBRIS_EGLPLATFORM=hwcomposer ANDROID_ROOT=/system
    stdbuf -o0 -e0 timeout 30 /root/build/libhybris/hybris/tests/.libs/test_hwcomposer > /tmp/hwc.out 2>&1
    echo "GUEST-TEST-RC=$?"
    tail -20 /tmp/hwc.out
'
kill $BLKEEP 2>/dev/null
