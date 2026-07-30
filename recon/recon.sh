#!/bin/sh
# Determination device recon (design spec §9). Run on the host with the phone on
# USB, adb authorized, and root available (Magisk `adb root` or `su`).
#
# Goal: determine whether an existing SM8150/845-family libhybris port drops in
# against these blobs or needs a modification pass. Everything downstream
# (libhybris backend choice, gralloc/mapper pairing) is gated on this output.
#
# Usage: recon/recon.sh [--serial SERIAL] [output-dir]

set -u

SERIAL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --serial)
            [ "$#" -ge 2 ] || { echo "error: --serial needs a value" >&2; exit 2; }
            SERIAL=$2
            shift 2
            ;;
        --help|-h)
            echo "usage: recon/recon.sh [--serial SERIAL] [output-dir]"
            exit 0
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
        *)
            [ "$#" -eq 1 ] || { echo "error: only one output directory is allowed" >&2; exit 2; }
            OUT=$1
            shift
            ;;
    esac
done
OUT=${OUT:-recon/report-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
STATUS_FILE="$OUT/probe-status.tsv"
printf 'probe\tstatus\n' >"$STATUS_FILE"

command -v adb >/dev/null 2>&1 || {
    echo "error: adb is required; install official Android platform-tools" >&2
    exit 1
}

adb_cmd() {
    if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi
}

if [ -z "$SERIAL" ]; then
    CONNECTED=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
    COUNT=$(printf '%s\n' "$CONNECTED" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$COUNT" -ne 1 ]; then
        echo "error: select exactly one authorized device with --serial SERIAL" >&2
        exit 1
    fi
    SERIAL=$CONNECTED
fi

if ! adb_cmd get-state >/dev/null 2>&1; then
    echo "error: selected adb device is not ready: $SERIAL" >&2
    exit 1
fi

adb_cmd version >"$OUT/host-adb-version.txt" 2>&1
printf 'serial=%s\n' "$SERIAL" >"$OUT/host-target.txt"

# Use Magisk `su -c`; never restart adbd as root (that drops wireless ADB and
# is unnecessary on a rooted production build). Quote the entire command as
# one argument to su - adb otherwise reconstructs it as separate shell words
# and compound commands fail at the first `do`/`;`.
if [ "$(adb_cmd shell su -c id -u </dev/null 2>/dev/null | tr -d '\r')" = "0" ]; then
    ash() {
        escaped=$(printf '%s' "$*" | sed "s/'/'\\\\''/g")
        adb_cmd shell "su -c '$escaped'"
    }
else
    echo "error: no root on device (grant Shell in Magisk Superuser)" >&2
    exit 1
fi

run() { # run <name> <command...>
    name=$1; shift
    echo "== $name"
    if ash "$@" >"$OUT/$name.txt" 2>&1; then
        printf '%s\tok\n' "$name" >>"$STATUS_FILE"
    else
        printf '%s\tfailed\n' "$name" >>"$STATUS_FILE"
        echo "warn: probe failed: $name (see $OUT/$name.txt)" >&2
    fi
}

run fingerprint       'getprop ro.build.fingerprint; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.boot.slot_suffix'
run boot-layout       'slot=$(getprop ro.boot.slot_suffix); for p in boot vendor_boot init_boot; do for n in "$p$slot" "$p"; do [ -e "/dev/block/by-name/$n" ] && { echo "partition=$p"; echo "node=$(readlink -f /dev/block/by-name/$n)"; break; }; done; done; echo "slot=$slot"; echo "dynamic=$(getprop ro.boot.dynamic_partitions)"'

# Composer HAL flavour + version (HIDL 2.x vs AIDL composer3) and gralloc
run vendor-hw-libs    'ls -la /vendor/lib64/hw/ | grep -Ei "composer|gralloc|mapper|memtrack"'
run lshal-graphics    'lshal 2>/dev/null | grep -Ei "composer|graphics.mapper|allocator"'
run aidl-composer     'service list | grep -Ei "composer|SurfaceFlinger"'
run sf-dumpsys        'dumpsys SurfaceFlinger | head -n 60'

# GPU + dmabuf/ion nodes libhybris will drive
run dev-gpu           'ls -la /dev/kgsl-3d0 /dev/ion /dev/dma_heap/ /dev/dri/ 2>/dev/null'
run dev-binder        'ls -la /dev/binder* /dev/hwbinder /dev/vndbinder /dev/binderfs 2>/dev/null'
run dev-input         'ls -la /dev/input/; for d in /dev/input/event*; do echo "$d: $(cat /sys/class/input/$(basename $d)/device/name 2>/dev/null)"; done'
run dev-backlight     'for d in /sys/class/backlight/*; do [ -d "$d" ] || continue; echo "path=$d/brightness"; echo "max=$(cat "$d/max_brightness" 2>/dev/null)"; echo "actual=$(cat "$d/actual_brightness" 2>/dev/null)"; done'
run dev-network       'for d in /sys/class/net/*; do echo "$(basename "$d") type=$(cat "$d/type" 2>/dev/null) state=$(cat "$d/operstate" 2>/dev/null)"; done'
run dev-power         'for d in /sys/class/power_supply/*; do echo "[$(basename "$d")]"; cat "$d/type" "$d/capacity" "$d/voltage_now" 2>/dev/null; done'
run dev-drm           'ls -la /dev/dri 2>/dev/null; for d in /sys/class/drm/card*-*; do [ -e "$d/status" ] && echo "$(basename "$d")=$(cat "$d/status")"; done'
run identity          'echo "device=$(getprop ro.product.device)"; echo "vendor=$(getprop ro.product.vendor.device)"; echo "manufacturer=$(getprop ro.product.manufacturer)"; echo "model=$(getprop ro.product.model)"; cat /proc/device-tree/compatible 2>/dev/null | tr "\000" "\n"'

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

# Emit a conservative machine-readable starting point. Runtime discovery is
# still authoritative; this records only values recon can identify safely.
DEVICE=$(adb_cmd shell getprop ro.product.device </dev/null | tr -d '\r')
BACKLIGHT=$(ash 'for d in /sys/class/backlight/backlight/brightness /sys/class/backlight/panel0-backlight/brightness /sys/class/backlight/*/brightness; do [ -e "$d" ] && { echo "$d"; break; }; done' | tr -d '\r')
BLMAX=$(ash "cat '${BACKLIGHT%/brightness}/max_brightness' 2>/dev/null" | tr -d '\r')
WIFI=$(ash 'for d in /sys/class/net/wlan* /sys/class/net/wifi*; do [ -e "$d" ] && { basename "$d"; break; }; done' | tr -d '\r')
DRM=$(ash 'for d in /dev/dri/card*; do [ -e "$d" ] && { echo "$d"; break; }; done' | tr -d '\r')
BATTERY=$(ash 'for n in bms battery; do [ -r "/sys/class/power_supply/$n/capacity" ] && { echo "$n"; break; }; done' | tr -d '\r')
PANEL=$(ash 'wm size 2>/dev/null' | tr -d '\r' | sed -n 's/.*Physical size: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | head -n 1)
{
    echo "# Generated by recon/recon.sh for review; data only."
    echo "DET_PROFILE_ID=${DEVICE:-unknown}"
    [ -n "$BACKLIGHT" ] && echo "DET_BACKLIGHT_PATH=$BACKLIGHT"
    [ -n "$BLMAX" ] && echo "# DET_BACKLIGHT_LEVEL=$((BLMAX / 3))"
    [ -n "$WIFI" ] && echo "DET_WIFI_IFACE=$WIFI"
    [ -n "$DRM" ] && echo "DET_DRM_CARD=$DRM"
    [ -n "$BATTERY" ] && echo "DET_BATTERY_GAUGE=$BATTERY"
    if [ -n "$PANEL" ]; then
        echo "DET_PANEL_WIDTH=${PANEL%% *}"
        echo "DET_PANEL_HEIGHT=${PANEL#* }"
    fi
} > "$OUT/device.conf"

if command -v python3 >/dev/null 2>&1; then
    python3 "$(dirname "$0")/classify.py" "$OUT" || echo "WARN: capability classification failed"
else
    echo "WARN: python3 unavailable; skipping capability classification"
fi

echo
echo "Report in $OUT/"
echo "Read order: vendor-hw-libs + lshal-graphics (composer/gralloc pairing),"
echo "then kernel-config (what the custom kernel must add)."
echo "Review $OUT/device.conf before installing it as /data/determination/etc/device.conf."
echo "Compatibility decision: $OUT/compatibility.txt"
