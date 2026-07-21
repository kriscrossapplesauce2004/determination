#!/system/bin/sh
# Determination late-boot service: prepare the guest environment once Android is
# up. Does NOT start desktop mode — that's user-triggered via
# /data/determination/bin/desktop-on. External-display convergence (spec §5) can
# start the guest compositor here concurrently once DP-alt enumeration works.

MODDIR=${0%/*}
DET=/data/determination
# Rotate the append-forever log once it passes ~256K (keep the newest half).
[ "$(stat -c %s "$DET/log/service.log" 2>/dev/null || echo 0)" -gt 262144 ] &&
    tail -c 131072 "$DET/log/service.log" > "$DET/log/service.log.tmp" &&
    mv "$DET/log/service.log.tmp" "$DET/log/service.log"
exec >>"$DET/log/service.log" 2>&1
echo "--- service $(date)"

# Wait for full boot before touching anything.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done

# Guest cgroup delegation (cgroup v2 hierarchy; Android mounts it at /sys/fs/cgroup).
mkdir -p /sys/fs/cgroup/determination 2>/dev/null

# Sanity: the Determination kernel must provide pid namespaces (LXC hard
# requirement, missing from the stock crDroid kernel) and binderfs.
grep -q pid /proc/self/ns/pid 2>/dev/null || [ -e /proc/self/ns/pid ] || echo "WARN: no pid ns — wrong kernel?"
[ -d /dev/binderfs ] || echo "WARN: binderfs missing — wrong kernel?"

# Guest networking: veth pair NAT'd through the phone's active connection is
# set up by lxc from guest/lxc/config; here we just make sure forwarding is on.
echo 1 > /proc/sys/net/ipv4/ip_forward
# Kernel #3 adds IPv6 NAT (NF_NAT_IPV6/IP6_NF_TARGET_MASQUERADE) — turn on v6
# forwarding too so the guest isn't v4-only on v6-only carrier networks.
# Fails harmlessly (logged) on older Determination kernels.
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding || echo "WARN: no v6 forwarding (pre-#3 kernel?)"

# Native control plane, migration wave 1. It is deliberately observe-only:
# status/doctor/capabilities are live, while the proven transition scripts
# remain authoritative until journal/recovery hardware tests pass. A daemon
# failure cannot change display ownership or prevent the emergency desktop-off
# path from working.
if [ -x "$DET/bin/detd" ]; then
    [ "$(stat -c %s "$DET/log/detd.log" 2>/dev/null || echo 0)" -gt 262144 ] &&
        tail -c 131072 "$DET/log/detd.log" > "$DET/log/detd.log.tmp" &&
        mv "$DET/log/detd.log.tmp" "$DET/log/detd.log"
    if [ -S "$DET/run/detd.sock" ] && "$DET/bin/detctl" ping >/dev/null 2>&1; then
        echo "detd already running"
    else
        rm -f "$DET/run/detd.sock" "$DET/run/detd.pid"
        setsid "$DET/bin/detd" --root "$DET" --observe-only \
            >>"$DET/log/detd.log" 2>&1 &
        echo $! > "$DET/run/detd.pid"
        i=0
        while [ ! -S "$DET/run/detd.sock" ] && [ $i -lt 20 ]; do
            i=$((i+1)); sleep 0.1
        done
        if "$DET/bin/detctl" ping >/dev/null 2>&1; then
            echo "detd observe-only control plane ready"
        else
            echo "WARN: detd failed its boot ping (legacy controls unaffected)"
        fi
    fi
fi

# The SM8150 composer advertises display color-transform support but silently
# ignores Night Light's matrix for hardware-composed layers. The compatibility
# watcher leaves Android's own ColorDisplay settings untouched and asks
# SurfaceFlinger for client composition only while Night Light is active.
if [ -x "$DET/bin/det-color-compat" ]; then
    if [ -f "$DET/run/color-compat.pid" ]; then
        oldpid=$(cat "$DET/run/color-compat.pid" 2>/dev/null)
        [ -n "$oldpid" ] && kill "$oldpid" 2>/dev/null
    fi
    setsid "$DET/bin/det-color-compat" \
        >>"$DET/log/color-compat.log" 2>&1 &
    echo $! > "$DET/run/color-compat.pid"
fi

# Start the (headless, no display acquisition) guest container so desktop-on
# only has to do the display/input handoff, not a cold boot of Debian.
if [ -x "$DET/bin/guest-start" ]; then
    "$DET/bin/guest-start" || echo "WARN: guest-start failed"
fi
