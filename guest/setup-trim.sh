#!/bin/bash
# setup-trim.sh --- in-guest, idempotent. Cuts background fat from the Debian
# guest: surprise-work timers, daemons nothing consumes, unbounded journal,
# and the doc/man payload on a phone that will never read it.
#
# WHY THIS EXISTS (2026-07-10): the stock trixie rootfs ships apt-daily +
# apt-daily-upgrade timers LIVE --- unattended apt traffic at random hours,
# which is exactly the workload correlated with the 07-06 spontaneous
# reboots/kernel panic (guest apt traffic churning the wlan driver), and in
# desktop mode the guest's network is flaky anyway (system_server crash-loop
# takes WiFi down). All package work here is deliberate and scripted; nothing
# should apt behind our back.
#
# Run inside the container as root (lxc-attach ... -- /root/setup-trim.sh),
# in PHONE mode is fine --- no network needed.
set -eu
# lxc-attach hands scripts a minimal PATH (no /usr/bin) --- same gotcha as
# setup-controls.sh.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "== mask surprise-work timers =="
# apt-daily*: see header. e2scrub_all: scrubs LVM ext4 volumes --- there are
# none (rootfs is a bind of host /data). fstrim: TRIM through the container's
# rootfs bind --- the host owns the flash, not the guest's business.
# dpkg-db-backup + logrotate + tmpfiles-clean stay: cheap, genuinely useful
# (battery deaths mid-apt have happened --- a dpkg status backup earns its keep).
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer \
    e2scrub_all.timer fstrim.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
# mask --now on a live timer leaves it ACTIVE=failed (cosmetic, but it flips
# is-system-running to "degraded") --- clear the residue.
systemctl reset-failed 2>/dev/null || true

echo "== disable daemons nothing consumes =="
# avahi: no mDNS consumer --- the host reaches the guest at 192.168.117.2
# directly, and nothing on the LAN talks to the container. Periodic network
# chatter for nobody.
# cron: empty crontabs; its only real job would be /etc/cron.{daily,weekly}
# which duplicates what the systemd timers (above) already own.
systemctl disable --now avahi-daemon.service avahi-daemon.socket \
    cron.service 2>/dev/null || true

echo "== cap journald =="
# The journal lives on the host's /data flash via the rootfs bind --- unbounded
# growth is both space and flash wear. 32M is days of logs at our volume.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/determination.conf <<'EOF'
[Journal]
SystemMaxUse=32M
RuntimeMaxUse=16M
EOF
systemctl try-restart systemd-journald 2>/dev/null || true

echo "== apt/dpkg diet (future installs) =="
# The setup scripts already pass --no-install-recommends everywhere; make it
# the default so ad-hoc `apt install` from a guest terminal behaves the same.
# (Remember the gnome-settings-daemon-common lesson: if an app misbehaves,
# check its Recommends first.)
cat > /etc/apt/apt.conf.d/90determination-norecommends <<'EOF'
APT::Install-Recommends "false";
EOF
# No man pages / docs on the phone (keep Debian copyright files).
cat > /etc/dpkg/dpkg.cfg.d/90determination-trim <<'EOF'
path-exclude=/usr/share/man/*
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
EOF

echo "== purge existing docs/man + apt caches =="
before=$(du -sm /usr/share/doc /usr/share/man /var/cache/apt 2>/dev/null | awk '{s+=$1} END {print s}')
find /usr/share/doc -depth -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -depth -type d -empty -delete 2>/dev/null || true
rm -rf /usr/share/man/* 2>/dev/null || true
apt-get clean
after=$(du -sm /usr/share/doc /usr/share/man /var/cache/apt 2>/dev/null | awk '{s+=$1} END {print s}')
echo "reclaimed ~$((before - after)) MB (doc/man/apt-cache: ${before}MB -> ${after}MB)"

echo "== state check =="
systemctl list-timers --all --no-pager | sed -n '1,12p'
echo "SETUP-TRIM-OK"
