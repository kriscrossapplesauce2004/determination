#!/system/bin/sh
# GPU app-buffer gate: verify Wayland clients render on the GPU via hybris'
# wayland EGL platform (android_wlegl -> phoc android renderer EGLImage),
# not wl_shm. Run ON THE PHONE as root.
#
# Two modes:
#   gpu-smoke.sh prep   — PHONE MODE (guest network only reliable there):
#                         installs the test clients into the guest.
#   gpu-smoke.sh        — DESKTOP MODE (desktop-on running, phoc socket up):
#                         runs the actual gate. Windows will appear on the
#                         panel; melissa should be told before running.
#
# Pass criteria:
#   1. hybris wayland EGL platform plugin installed.
#   2. wayland-info lists the android_wlegl global (phoc serves it).
#   3. glmark2-es2-wayland runs and reports a real GPU renderer (Adreno on
#      this device) with a sane FPS — this isolates the EGL/buffer path
#      from GTK. NOTE: hybris' wayland platform abort()s the process if
#      android_wlegl is missing — that counts as a loud FAIL, not a crash
#      mystery.
#   4. A GTK4 app (gnome-calculator) maps HYBRIS libEGL (/usr/local/lib),
#      and GDK_DEBUG=opengl shows an EGL context, no cairo fallback.
# Evidence goes to stdout — capture to artifacts/ on the host (mind the
# su quoting rule: the whole chain in ONE quoted arg):
#   adb push guest/gpu-smoke.sh /data/local/tmp/
#   adb shell "su -c 'sh /data/local/tmp/gpu-smoke.sh prep'"   # phone mode
#   adb shell "su -c 'sh /data/local/tmp/gpu-smoke.sh'" \
#       | tee artifacts/guest-gpu-smoke-$(date +%Y%m%d).txt    # desktop mode
set -u
DET=/data/determination
LXC="$DET/lxc/bin/lxc-attach -P $DET -n guest --"

if [ "${1:-}" = "prep" ]; then
    exec $LXC /bin/sh -c '
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            glmark2-es2-wayland wayland-utils
        echo "GPU-SMOKE-PREP-OK"
    '
fi

[ -f "$DET/run/desktop-mode" ] || {
    echo "FATAL: desktop mode not active — run desktop-on first (and warn melissa: windows will appear)"; exit 1; }

$LXC /bin/sh -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    # Same env contract as the desktop-on 5e client session — this is what
    # every phosh-launched app runs with.
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu
    export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
    export EGL_PLATFORM=wayland HYBRIS_EGLPLATFORM=wayland ANDROID_ROOT=/system
    export XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 LANG=C.UTF-8
    export TMPDIR=/tmp GSK_RENDERER=ngl
    fail=0

    echo "== 1. hybris wayland EGL platform plugin =="
    if ls -l /usr/local/lib/libhybris/eglplatform_wayland.so; then
        echo "PLATFORM-PLUGIN: OK"
    else
        echo "PLATFORM-PLUGIN: FAIL (rebuild guest/build-libhybris.sh)"; fail=1
    fi

    echo "== 2. compositor serves android_wlegl =="
    [ -S "$XDG_RUNTIME_DIR/wayland-0" ] || { echo "FATAL: no wayland socket"; exit 3; }
    if command -v wayland-info >/dev/null; then
        if wayland-info 2>/dev/null | grep -A1 android_wlegl | head -3 | grep -q android_wlegl; then
            echo "ANDROID-WLEGL-GLOBAL: OK"
        else
            echo "ANDROID-WLEGL-GLOBAL: FAIL — phoc is not serving it (android renderer not active?)"; fail=1
        fi
    else
        echo "SKIP: wayland-info not installed (run gpu-smoke.sh prep in phone mode)"
    fi

    echo "== 3. pure EGL/GLES wayland client (glmark2-es2-wayland) =="
    if command -v glmark2-es2-wayland >/dev/null; then
        # -b build:duration=5 keeps it short; --fullscreen exercises the
        # panel-size buffer path. rc 0 or 124 both fine — the renderer
        # line is the verdict.
        timeout 40 glmark2-es2-wayland -b build:duration=5 -b texture:duration=5 \
            --fullscreen > /tmp/glmark2.out 2>&1
        rc=$?
        grep -E "GL_RENDERER|GL_VERSION|EGL|FPS|Score|Error|error" /tmp/glmark2.out | head -20
        if grep -q "GL_RENDERER.*Adreno\|GL_RENDERER.*Mali\|GL_RENDERER.*PowerVR" /tmp/glmark2.out; then
            echo "GLMARK2: OK rc=$rc (vendor GPU renderer in a wayland client)"
        else
            echo "GLMARK2: FAIL rc=$rc (no vendor GL_RENDERER — see /tmp/glmark2.out)"; fail=1
        fi
    else
        echo "SKIP: glmark2-es2-wayland not installed (run gpu-smoke.sh prep in phone mode)"
    fi

    echo "== 4. GTK4 app on the GPU path (gnome-calculator) =="
    if command -v gnome-calculator >/dev/null; then
        GDK_DEBUG=opengl timeout 15 gnome-calculator > /tmp/gtkgl.out 2>&1 &
        GPID=$!
        sleep 6
        APP=$(pgrep -n gnome-calculat || true)
        if [ -n "$APP" ]; then
            EGLMAP=$(grep -m1 "libEGL" "/proc/$APP/maps" || true)
            echo "libEGL mapping: ${EGLMAP:-NONE}"
            case "$EGLMAP" in
                */usr/local/lib/*) echo "GTK4-EGL: OK (hybris libEGL)";;
                "") echo "GTK4-EGL: FAIL — no EGL at all (cairo/shm fallback)"; fail=1;;
                *) echo "GTK4-EGL: FAIL — wrong libEGL (glvnd/Mesa won the path)"; fail=1;;
            esac
        else
            echo "GTK4-EGL: FAIL — calculator not running (crashed? /tmp/gtkgl.out below)"; fail=1
        fi
        wait $GPID 2>/dev/null
        echo "-- GDK opengl debug (first 25 relevant lines):"
        grep -iE "egl|opengl|renderer|context|fallback|cairo" /tmp/gtkgl.out | head -25
    else
        echo "SKIP: gnome-calculator not installed (guest/setup-polish.sh)"
    fi

    echo "== VERDICT =="
    [ "$fail" = 0 ] && echo "GPU-SMOKE: ALL PASS" || echo "GPU-SMOKE: FAILURES (see above)"
    exit $fail
'
