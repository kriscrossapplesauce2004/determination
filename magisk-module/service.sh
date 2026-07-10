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

# Start the (headless, no display acquisition) guest container so desktop-on
# only has to do the display/input handoff, not a cold boot of Debian.
if [ -x "$DET/bin/guest-start" ]; then
    "$DET/bin/guest-start" || echo "WARN: guest-start failed"
fi
