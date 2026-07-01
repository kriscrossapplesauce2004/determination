#!/system/bin/sh
# DecemberOS late-boot service: prepare the guest environment once Android is
# up. Does NOT start desktop mode — that's user-triggered via
# /data/decemberos/bin/desktop-on. External-display convergence (spec §5) can
# start the guest compositor here concurrently once DP-alt enumeration works.

MODDIR=${0%/*}
DOS=/data/decemberos
exec >>"$DOS/log/service.log" 2>&1
echo "--- service $(date)"

# Wait for full boot before touching anything.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done

# Guest cgroup delegation (cgroup v2 hierarchy; Android mounts it at /sys/fs/cgroup).
mkdir -p /sys/fs/cgroup/decemberos 2>/dev/null

# Guest binder nodes: the custom kernel creates extra binder contexts
# (guest-binder etc., see kernel/decemberos.config). Make sure they exist and
# are reachable for the container config's bind-mounts.
ls -l /dev/guest-binder >/dev/null 2>&1 || echo "WARN: guest binder nodes missing — wrong kernel?"

# Guest networking: veth pair NAT'd through the phone's active connection is
# set up by lxc from guest/lxc/config; here we just make sure forwarding is on.
echo 1 > /proc/sys/net/ipv4/ip_forward

# Start the (headless, no display acquisition) guest container so desktop-on
# only has to do the display/input handoff, not a cold boot of Debian.
if [ -x "$DOS/bin/guest-start" ]; then
    "$DOS/bin/guest-start" || echo "WARN: guest-start failed"
fi
