#!/bin/bash
# setup-controls.sh — in-guest, idempotent. Installs the phosh-side triggers
# for the guest->host control channel (host side is toggle/det-hostagent over
# /mnt/det-control, bind-mounted from /data/determination/run/control):
#
#   1. det-signal            tiny helper: drop a command file for the host agent
#   2. app-grid launchers    Exit to Phone Mode / Power Off / Restart
#   3. systemd shutdown hooks map phosh's NATIVE power menu (Power Off /
#      Restart) onto host actions, run BEFORE unmount so /mnt/det-control is
#      still there
#   4. pin "Exit to Phone Mode" to phosh favourites
#
# Run inside the container (lxc-attach ... -- /root/setup-controls.sh). No
# network needed. Mirror of the on-device customiser like setup-input/polish.
set -eu
# lxc-attach hands this script a minimal PATH; systemctl / gsettings /
# dbus-run-session / update-desktop-database all live in /usr/bin and were
# silently skipped without this (found on first on-device run 2026-07-08).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CTRL=/mnt/det-control

echo "== det-signal helper =="
install -d /usr/local/sbin
cat > /usr/local/sbin/det-signal <<EOF
#!/bin/sh
# Ask the Determination host agent to run a host-privileged action. The guest
# cannot leave desktop mode or power the phone itself — it drops a command file
# the agent (Android root) consumes. See toggle/det-hostagent.
CTRL=$CTRL
case "\${1:-}" in
    exit|reboot|poweroff) ;;
    *) echo "usage: det-signal exit|reboot|poweroff" >&2; exit 2 ;;
esac
if [ ! -d "\$CTRL" ]; then
    echo "det-signal: control channel \$CTRL not mounted — is the guest" >&2
    echo "            started under the current lxc config? (needs restart)" >&2
    exit 1
fi
: > "\$CTRL/\$1" && echo "det-signal: requested '\$1' from host"
EOF
chmod 0755 /usr/local/sbin/det-signal

echo "== app-grid launchers =="
install -d /usr/share/applications
# NoDisplay=false so they appear in the phosh app grid. Categories=System so
# they group sensibly. Icons are stock Adwaita names (adwaita-icon-theme is
# already pulled in by setup-polish for squeekboard).
cat > /usr/share/applications/determination-exit.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Exit to Phone Mode
Comment=Hand the display back to Android and return to the phone UI
Exec=det-signal exit
Icon=system-log-out
Terminal=false
Categories=System;
X-Purism-FormFactor=Workstation;Mobile;
Keywords=phone;android;exit;desktop;determination;
EOF
cat > /usr/share/applications/determination-poweroff.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Power Off Phone
Comment=Shut the whole phone down from desktop mode
Exec=det-signal poweroff
Icon=system-shutdown
Terminal=false
Categories=System;
X-Purism-FormFactor=Workstation;Mobile;
Keywords=power;shutdown;off;determination;
EOF
cat > /usr/share/applications/determination-reboot.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Restart Phone
Comment=Reboot the whole phone from desktop mode
Exec=det-signal reboot
Icon=system-reboot
Terminal=false
Categories=System;
X-Purism-FormFactor=Workstation;Mobile;
Keywords=reboot;restart;determination;
EOF
update-desktop-database /usr/share/applications 2>/dev/null || true

echo "== systemd shutdown hooks (map phosh's native power menu) =="
# phosh's top-bar power menu calls logind PowerOff/Reboot -> systemd isolates
# poweroff.target / reboot.target. Inside a container that only stops the
# container, NOT the phone. These oneshots run as those targets are reached
# but ORDERED BEFORE umount.target, so /mnt/det-control is still mounted, and
# forward the intent to the host agent (which powers/reboots the real phone).
install -d /etc/systemd/system
cat > /etc/systemd/system/det-poweroff-signal.service <<EOF
[Unit]
Description=Determination: signal host to power off the phone
DefaultDependencies=no
Before=umount.target shutdown.target poweroff.target
Conflicts=reboot.target

[Service]
Type=oneshot
ExecStart=-/usr/local/sbin/det-signal poweroff

[Install]
WantedBy=poweroff.target
EOF
cat > /etc/systemd/system/det-reboot-signal.service <<EOF
[Unit]
Description=Determination: signal host to reboot the phone
DefaultDependencies=no
Before=umount.target shutdown.target reboot.target
Conflicts=poweroff.target

[Service]
Type=oneshot
ExecStart=-/usr/local/sbin/det-signal reboot

[Install]
WantedBy=reboot.target
EOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable det-poweroff-signal.service det-reboot-signal.service 2>/dev/null || true

echo "== pin 'Exit to Phone Mode' to phosh favourites =="
# Prepend our exit launcher if not already present; leave the rest untouched.
dbus-run-session -- /bin/sh -c '
    cur=$(gsettings get sm.puri.phosh favorites 2>/dev/null || echo "@as []")
    case "$cur" in
        *determination-exit.desktop*) echo "already pinned" ;;
        "@as []"|"[]"|"")
            gsettings set sm.puri.phosh favorites "['\''determination-exit.desktop'\'']" &&
            echo "pinned (fresh list)" ;;
        *)
            new=$(printf "%s" "$cur" | sed "s/^\[/['\''determination-exit.desktop'\'', /")
            gsettings set sm.puri.phosh favorites "$new" && echo "pinned -> $new" ;;
    esac
' || echo "note: could not set phosh favorites (key absent?) — launcher still in app grid"

echo "== done =="
echo "Power menu (Power Off / Restart) + app-grid tiles now drive the host."
echo "Requires the guest to be running under the lxc config that binds"
echo "/mnt/det-control (restart the container / reboot after installing the"
echo "new module if 'det-signal' reports the channel isn't mounted)."
