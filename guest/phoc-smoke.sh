#!/system/bin/sh
# §3 FINISH gate: stop SF, run PHOC (droidian wlroots hwcomposer backend,
# built in-guest against upstream libhybris), connect a foot terminal as a
# separate Wayland client, restore SF regardless of outcome. Run as root.
#
# phoc is started WITHOUT -E: glib's child watch is broken on kernel 4.14
# (no pidfd; waitid(P_PIDFD) EINVAL) so phoc mis-detects the session child
# as dead and shuts down (found 2026-07-06). Clients must be launched
# separately from the compositor.
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
    for i in $(seq 40); do
        echo 2048 > $BL 2>/dev/null
        sleep 2
    done
) &
BLKEEP=$!
/data/decemberos/lxc/bin/lxc-attach -P /data/decemberos -n guest -- /bin/sh -c '
    export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu
    export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
    export EGL_PLATFORM=hwcomposer HYBRIS_EGLPLATFORM=hwcomposer ANDROID_ROOT=/system TMPDIR=/tmp
    export WLR_BACKENDS=hwcomposer
    export XDG_RUNTIME_DIR=/run/user/0 LANG=C.UTF-8
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    rm -f "$XDG_RUNTIME_DIR"/wayland-0 "$XDG_RUNTIME_DIR"/wayland-0.lock
    stdbuf -oL -eL /usr/local/bin/phoc -v > /tmp/phoc.out 2>&1 &
    PHOC=$!
    i=0
    until [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; do
        i=$((i+1)); [ $i -gt 40 ] && { echo NO-WAYLAND-SOCKET; kill $PHOC; exit 1; }
        sleep 0.5
    done
    echo "WAYLAND SOCKET UP after ${i} half-seconds"
    export WAYLAND_DISPLAY=wayland-0
    timeout 40 foot -- /bin/sh -c "echo DecemberOS: Debian $(cat /etc/debian_version) on $(uname -r); echo; cat /etc/os-release | head -2; exec /bin/bash" > /tmp/foot.out 2>&1
    FOOT_RC=$?
    echo "FOOT-RC=$FOOT_RC (124=lived full 40s window = GOOD)"
    kill $PHOC 2>/dev/null
    sleep 1
    echo "--- phoc log tail:"; tail -25 /tmp/phoc.out
    echo "--- foot log:"; cat /tmp/foot.out
'
kill $BLKEEP 2>/dev/null
