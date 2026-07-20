#!/system/bin/sh
# Device-side, self-restoring smoke test for the standalone HWC transition.
# Runs in phone mode: stops SF, renders one finite sequence, then restores SF.
set -u

DET=/data/determination
. "$DET/bin/device-config"

BL=$DET_BACKLIGHT_PATH
OLD_BL=
[ -n "$BL" ] && OLD_BL=$(cat "$BL" 2>/dev/null)

restore() {
    start surfaceflinger
    i=0
    until [ "$(getprop init.svc.surfaceflinger)" = "running" ]; do
        i=$((i+1)); [ "$i" -gt 20 ] && break
        sleep 0.5
    done
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
        i=0
        while [ "$i" -lt 20 ]; do
            [ "$(getprop init.svc.bootanim)" = running ] && break
            i=$((i+1)); sleep 0.5
        done
        setprop service.bootanim.exit 1
        setprop service.bootanim.progress 1
        sleep 1
        [ "$(getprop init.svc.bootanim)" = running ] && stop bootanim
    fi
    [ -n "$BL" ] && [ -n "$OLD_BL" ] && echo "$OLD_BL" > "$BL" 2>/dev/null
    echo "SF=$(getprop init.svc.surfaceflinger) bootanim=$(getprop init.svc.bootanim)"
}
trap restore EXIT

stop surfaceflinger
i=0
while [ "$(getprop init.svc.surfaceflinger)" != stopped ]; do
    i=$((i+1)); [ "$i" -gt 20 ] && { echo "FATAL: SF did not stop"; exit 1; }
    sleep 0.1
done
sleep 0.5
[ -n "$BL" ] && echo "$DET_BACKLIGHT_LEVEL" > "$BL" 2>/dev/null

"$DET/lxc/bin/lxc-attach" -P "$DET" -n guest -- /bin/sh -c '
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu
    export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
    export EGL_PLATFORM=hwcomposer HYBRIS_EGLPLATFORM=hwcomposer ANDROID_ROOT=/system TMPDIR=/tmp
    exec /usr/local/bin/det-transition desktop
'
