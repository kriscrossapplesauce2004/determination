#!/system/bin/sh
# M5 native-DRM track, Phase 0.1: READ-ONLY enumeration of the downstream SDE
# DRM/KMS device (/dev/dri/card0) from inside the guest. Safe to run while
# Android owns the display — no master is taken, nothing is committed.
#
# Key questions this answers (plan: m5 native-DRM track):
#   - driver name/version the guest sees (drmGetVersion — minigbm backend
#     selection keys off this)
#   - does the DP-alt connector enumerate on card0 alongside the DSI panel?
#   - atomic cap, plane inventory, format+modifier lists (UBWC present?)
#
# Two modes, like gpu-smoke.sh:
#   kms-probe.sh prep   — PHONE MODE: apt-installs the probe tools.
#   kms-probe.sh        — any mode: runs the read-only dump.
# Capture on the host:
#   adb shell "su -c 'sh /data/local/tmp/kms-probe.sh'" \
#       | tee artifacts/kms-probe-$(date +%Y%m%d).txt
set -u
DET=/data/determination
LXC="$DET/lxc/bin/lxc-attach -P $DET -n guest --"

if [ "${1:-}" = "prep" ]; then
    exec $LXC /bin/sh -c '
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends libdrm-tests drm-info
        echo "KMS-PROBE-PREP-OK"
    '
fi

exec $LXC /bin/sh -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    echo "== nodes =="
    ls -la /dev/dri
    echo "== sysfs connectors (host /sys, ro) =="
    for c in /sys/class/drm/card0-*; do
        [ -e "$c" ] || continue
        printf "%s: status=%s enabled=%s\n" "${c##*/}" \
            "$(cat "$c/status" 2>/dev/null)" "$(cat "$c/enabled" 2>/dev/null)"
    done
    echo "== drm_info (full dump) =="
    if command -v drm_info >/dev/null; then
        drm_info /dev/dri/card0 2>&1
    else
        echo "SKIP: drm_info not installed (run kms-probe.sh prep in phone mode)"
    fi
    echo "== modetest (read-only, no -s) =="
    if command -v modetest >/dev/null; then
        # -M msm first (downstream SDE registers as "msm"); fall back to
        # autodetect if the name differs.
        modetest -M msm 2>/dev/null || modetest 2>&1
    else
        echo "SKIP: modetest not installed (libdrm-tests)"
    fi
    echo "KMS-PROBE-DONE"
'
