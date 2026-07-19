#!/bin/sh
# Build and run the compatibility graphics seam probe INSIDE the guest.
# Requires upstream libhybris in /usr/local and minigbm in /opt/minigbm.
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SRC=${1:-/root/hybris-minigbm-probe.c}
MODE=${2:-probe}
OUT=/usr/local/bin/hybris-minigbm-probe

[ -r "$SRC" ] || {
    echo "FATAL: probe source missing: $SRC" >&2
    echo "Push guest/hybris-minigbm-probe.c into the guest first." >&2
    exit 2
}
[ -f /usr/local/lib/libEGL.so.1 ] || {
    echo "FATAL: upstream libhybris missing; run guest/build-libhybris.sh" >&2
    exit 2
}
[ -f /opt/minigbm/lib/libgbm.so.1 ] || {
    echo "FATAL: minigbm missing; run guest/build-minigbm.sh" >&2
    exit 2
}

cc -std=c11 -O2 -Wall -Wextra -Werror \
    -I/usr/local/include -I/opt/minigbm/include \
    $(pkg-config --cflags libdrm) \
    "$SRC" -o "$OUT" \
    -L/usr/local/lib -L/opt/minigbm/lib \
    -Wl,-rpath,/usr/local/lib -Wl,-rpath,/opt/minigbm/lib \
    -lEGL -lGLESv2 -lgbm -lhybris-common

echo "== libhybris vendor EGL + Android gralloc + minigbm gate =="
export LD_LIBRARY_PATH=/usr/local/lib:/opt/minigbm/lib
export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
export ANDROID_ROOT=/system
[ -r /etc/determination-device.conf ] && . /etc/determination-device.conf
: "${DET_GRAPHICS_RENDERER:=libhybris}"
: "${DET_GBM_PROVIDER:=minigbm}"
[ "$DET_GRAPHICS_RENDERER" = libhybris ] || {
    echo "FATAL: compatibility probe requires DET_GRAPHICS_RENDERER=libhybris" >&2
    exit 2
}
[ "$DET_GBM_PROVIDER" = minigbm ] || {
    echo "FATAL: compatibility probe requires DET_GBM_PROVIDER=minigbm" >&2
    exit 2
}
# Null owns no display but still initializes vendor EGL and gralloc. This gate
# is safe in phone mode and cannot steal hwcomposer from SurfaceFlinger.
export EGL_PLATFORM=null HYBRIS_EGLPLATFORM=null
case "$MODE" in
    probe)
        exec "$OUT" "${DET_DRM_RENDER_NODE:-/dev/dri/renderD128}"
        ;;
    benchmark)
        fb_size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true)
        bench_width=${3:-${DET_PANEL_WIDTH:-${fb_size%,*}}}
        bench_height=${4:-${DET_PANEL_HEIGHT:-${fb_size#*,}}}
        bench_frames=${5:-240}
        bench_width=${bench_width:-1080}
        bench_height=${bench_height:-2340}
        exec "$OUT" "${DET_DRM_RENDER_NODE:-/dev/dri/renderD128}" \
            --benchmark "$bench_width" "$bench_height" "$bench_frames"
        ;;
    *)
        echo "FATAL: mode must be probe or benchmark" >&2
        exit 2
        ;;
esac
