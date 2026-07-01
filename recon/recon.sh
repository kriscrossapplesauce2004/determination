#!/bin/sh
# DecemberOS device recon (design spec §9). Run on the host with the phone on
# USB, adb authorized, and root available (Magisk `adb root` or `su`).
#
# Goal: determine whether an existing SM8150/845-family libhybris port drops in
# against these blobs or needs a modification pass. Everything downstream
# (libhybris backend choice, gralloc/mapper pairing) is gated on this output.
#
# Usage: recon/recon.sh [output-dir]

set -u

OUT="${1:-recon/report-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

if ! adb get-state >/dev/null 2>&1; then
    echo "error: no adb device" >&2
    exit 1
fi

# Prefer adb root; fall back to `su -c` (Magisk).
if adb root >/dev/null 2>&1 && [ "$(adb shell id -u)" = "0" ]; then
    ash() { adb shell "$@"; }
else
    ash() { adb shell su -c "$*"; }
    if [ "$(ash id -u | tr -d '\r')" != "0" ]; then
        echo "error: no root on device (need adb root or Magisk su)" >&2
        exit 1
    fi
fi

run() { # run <name> <command...>
    name=$1; shift
    echo "== $name"
    ash "$@" >"$OUT/$name.txt" 2>&1
}

run fingerprint       'getprop ro.build.fingerprint; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.boot.slot_suffix'

# Composer HAL flavour + version (HIDL 2.x vs AIDL composer3) and gralloc
run vendor-hw-libs    'ls -la /vendor/lib64/hw/ | grep -Ei "composer|gralloc|mapper|memtrack"'
run lshal-graphics    'lshal 2>/dev/null | grep -Ei "composer|graphics.mapper|allocator"'
run aidl-composer     'service list | grep -Ei "composer|SurfaceFlinger"'
run sf-dumpsys        'dumpsys SurfaceFlinger | head -n 60'

# GPU + dmabuf/ion nodes libhybris will drive
run dev-gpu           'ls -la /dev/kgsl-3d0 /dev/ion /dev/dma_heap/ /dev/dri/ 2>/dev/null'
run dev-binder        'ls -la /dev/binder* /dev/hwbinder /dev/vndbinder /dev/binderfs 2>/dev/null'
run dev-input         'ls -la /dev/input/; for d in /dev/input/event*; do echo "$d: $(cat /sys/class/input/$(basename $d)/device/name 2>/dev/null)"; done'

# Vendor/HAL fingerprints; who currently holds display/input
run props-graphics    'getprop | grep -Ei "composer|gralloc|vndk|ro.hardware|vendor.sku|hwui|egl"'
run holders           'lsof 2>/dev/null | grep -Ei "kgsl|/dev/dri|event[0-9]" | head -n 100'

# Kernel side: version, existing container/namespace support in the stock kernel
run kernel-version    'cat /proc/version'
run kernel-config     'if [ -e /proc/config.gz ]; then zcat /proc/config.gz | grep -E "CONFIG_(NAMESPACES|USER_NS|PID_NS|NET_NS|UTS_NS|IPC_NS|CGROUPS|CGROUP_|MEMCG|VETH|BRIDGE|ANDROID_BINDER|ASHMEM|MEMFD|OVERLAY_FS|FUSE_FS|SECCOMP|POSIX_MQUEUE|DEVPTS)="; else echo "no /proc/config.gz"; fi'
run cgroups           'cat /proc/cgroups; echo ---; cat /proc/filesystems | grep cgroup'

# Property area + init service view (respawn-masking groundwork for the toggle)
run init-services     'getprop | grep -E "^\[init\.svc\." | grep -Ei "surfaceflinger|zygote|bootanim|vendor.hwcomposer"'
run prop-files        'ls -la /dev/__properties__/ | head -n 30'

echo
echo "Report in $OUT/"
echo "Read order: vendor-hw-libs + lshal-graphics (composer/gralloc pairing),"
echo "then kernel-config (what the custom kernel must add)."
