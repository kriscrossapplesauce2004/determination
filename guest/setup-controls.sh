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

echo "== det-session-manager (org.gnome.SessionManager shim) =="
# phosh + squeekboard both try to register with org.gnome.SessionManager and
# fail ("The name org.gnome.SessionManager was not provided by any .service
# files") because we run phosh BARE — no gnome-session (phosh-session would
# `phoc -E gnome-session`, and `phoc -E` is banned on this kernel: glib
# child-watch dies on the half-backported pidfd and phoc quits). This shim
# owns the name on phosh's session bus so those clients register cleanly, and
# it routes the session-manager verbs to the host control channel:
#   Logout()   -> det-signal exit      (log out of the desktop == back to phone)
#   Shutdown() -> det-signal poweroff
#   Reboot()   -> det-signal reboot
# Launched inside dbus-run-session by toggle/desktop-on (step 5e) BEFORE phosh.
# Pure gi/GDBus (python3 + PyGObject + Gio typelib are all in the rootfs).
#
# It ALSO plays gsd-power's unblank role (2026-07-11, the power-button wake
# fix). phosh can blank on its own (XF86PowerOff / idle -> wlr-output-power
# OFF) but has NO internal unblank path: the only code that can pass
# active=false is the org.gnome.ScreenSaver.SetActive DBus method, which
# gnome-settings-daemon's power plugin normally calls when the user becomes
# active again. We run phosh bare — nobody called it, so the screen never
# came back ("power kills the session"). The shim now mirrors gsd-power:
#   ScreenSaver ActiveChanged(true)  -> IdleMonitor.AddUserActiveWatch()
#   IdleMonitor WatchFired(our id)   -> ScreenSaver.SetActive(false)
# The active watch is phosh-side ext-idle-notify with timeout 0: it fires on
# the next input event (power key, touch), which phoc sees regardless of
# output power state.
install -d /usr/local/bin
cat > /usr/local/bin/det-session-manager <<'EOS'
#!/usr/bin/env python3
# Determination: minimal org.gnome.SessionManager that maps session verbs onto
# the guest->host control channel (/usr/local/sbin/det-signal). See setup-controls.sh.
import os, signal, subprocess, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

DET_SIGNAL = "/usr/local/sbin/det-signal"

# Children (det-signal) are fire-and-forget; auto-reap so we never leak zombies.
signal.signal(signal.SIGCHLD, signal.SIG_IGN)

def host(action):
    try:
        subprocess.Popen([DET_SIGNAL, action],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sys.stderr.write("det-session-manager: -> host %s\n" % action)
    except Exception as e:
        sys.stderr.write("det-session-manager: det-signal %s failed: %s\n" % (action, e))
    sys.stderr.flush()

SM_XML = """
<node>
  <interface name="org.gnome.SessionManager">
    <method name="RegisterClient">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="client_startup_id" direction="in"/>
      <arg type="o" name="client_id" direction="out"/>
    </method>
    <method name="UnregisterClient">
      <arg type="o" name="client_id" direction="in"/>
    </method>
    <method name="Inhibit">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="u" name="toplevel_xid" direction="in"/>
      <arg type="s" name="reason" direction="in"/>
      <arg type="u" name="flags" direction="in"/>
      <arg type="u" name="cookie" direction="out"/>
    </method>
    <method name="Uninhibit"><arg type="u" name="cookie" direction="in"/></method>
    <method name="IsInhibited">
      <arg type="u" name="flags" direction="in"/>
      <arg type="b" name="is_inhibited" direction="out"/>
    </method>
    <method name="GetClients"><arg type="ao" name="clients" direction="out"/></method>
    <method name="GetInhibitors"><arg type="ao" name="inhibitors" direction="out"/></method>
    <method name="IsAutostartConditionHandled">
      <arg type="s" name="condition" direction="in"/>
      <arg type="b" name="handled" direction="out"/>
    </method>
    <method name="Setenv">
      <arg type="s" name="variable" direction="in"/>
      <arg type="s" name="value" direction="in"/>
    </method>
    <method name="InitializationError">
      <arg type="s" name="message" direction="in"/>
      <arg type="b" name="fatal" direction="in"/>
    </method>
    <method name="CanShutdown"><arg type="b" name="is_available" direction="out"/></method>
    <method name="IsSessionRunning"><arg type="b" name="running" direction="out"/></method>
    <method name="Shutdown"/>
    <method name="Reboot"/>
    <method name="Logout"><arg type="u" name="mode" direction="in"/></method>
    <property name="SessionName" type="s" access="read"/>
    <property name="SessionIsActive" type="b" access="read"/>
    <property name="InhibitedActions" type="u" access="read"/>
    <property name="Renderer" type="s" access="read"/>
    <signal name="ClientAdded"><arg type="o" name="id"/></signal>
    <signal name="ClientRemoved"><arg type="o" name="id"/></signal>
    <signal name="SessionRunning"/>
    <signal name="SessionOver"/>
  </interface>
</node>
"""

CLIENT_XML = """
<node>
  <interface name="org.gnome.SessionManager.ClientPrivate">
    <method name="EndSessionResponse">
      <arg type="b" name="is_ok" direction="in"/>
      <arg type="s" name="reason" direction="in"/>
    </method>
    <signal name="Stop"/>
    <signal name="QueryEndSession"><arg type="u" name="flags"/></signal>
    <signal name="EndSession"><arg type="u" name="flags"/></signal>
    <signal name="CancelEndSession"/>
  </interface>
</node>
"""

SS_NAME = "org.gnome.ScreenSaver"
SS_PATH = "/org/gnome/ScreenSaver"
IM_NAME = "org.gnome.Mutter.IdleMonitor"
IM_PATH = "/org/gnome/Mutter/IdleMonitor/Core"

class WakeWatcher:
    """gsd-power's unblank role. phosh blanks by itself but the only unblank
    entry point it has is the org.gnome.ScreenSaver.SetActive(false) DBus
    method — normally called by gsd-power's user-active watch. Without this,
    a blank (power button or idle) is permanent: phoc's output re-enable is
    never requested. Mirror gsd-power: when the screensaver goes active,
    register a user-active watch with phosh's IdleMonitor (ext-idle-notify
    timeout 0 under the hood); when it fires on the next key/touch, call
    SetActive(false). Active watches are one-shot on the phosh side."""

    def __init__(self, conn):
        self.conn = conn
        self.watch_id = None
        conn.signal_subscribe(SS_NAME, SS_NAME, "ActiveChanged", SS_PATH,
                              None, Gio.DBusSignalFlags.NONE,
                              self.on_active_changed)
        conn.signal_subscribe(IM_NAME, IM_NAME, "WatchFired", IM_PATH,
                              None, Gio.DBusSignalFlags.NONE,
                              self.on_watch_fired)
        sys.stderr.write("det-session-manager: wake watcher armed\n")
        sys.stderr.flush()

    def log(self, msg):
        sys.stderr.write("det-session-manager: wake: %s\n" % msg)
        sys.stderr.flush()

    def call(self, name, path, iface, method, params, cb=None):
        def done(conn, res):
            try:
                ret = conn.call_finish(res)
            except Exception as e:
                self.log("%s failed: %s" % (method, e))
                return
            if cb:
                cb(ret)
        self.conn.call(name, path, iface, method, params, None,
                       Gio.DBusCallFlags.NONE, -1, None, done)

    def on_active_changed(self, conn, sender, path, iface, sig, params):
        active = params.unpack()[0]
        self.log("screensaver active=%s" % active)
        if active and self.watch_id is None:
            def got(ret):
                self.watch_id = ret.unpack()[0]
                self.log("active watch %d registered" % self.watch_id)
            self.call(IM_NAME, IM_PATH, IM_NAME, "AddUserActiveWatch",
                      None, got)
        elif not active and self.watch_id is not None:
            # Unblanked by someone else (e.g. DBus SetActive) — drop our watch
            # so stray input later doesn't fire a stale unblank.
            wid, self.watch_id = self.watch_id, None
            self.call(IM_NAME, IM_PATH, IM_NAME, "RemoveWatch",
                      GLib.Variant("(u)", (wid,)))

    def on_watch_fired(self, conn, sender, path, iface, sig, params):
        wid = params.unpack()[0]
        if wid != self.watch_id:
            return
        self.watch_id = None
        self.log("user active while blanked -> SetActive(false)")
        self.call(SS_NAME, SS_PATH, SS_NAME, "SetActive",
                  GLib.Variant("(b)", (False,)))

class SM:
    def __init__(self):
        self.conn = None
        self.clients = {}   # object_path -> registration id
        self.n = 0
        self.cookie = 0
        self.sm_info = Gio.DBusNodeInfo.new_for_xml(SM_XML).interfaces[0]
        self.cl_info = Gio.DBusNodeInfo.new_for_xml(CLIENT_XML).interfaces[0]

    def on_method(self, conn, sender, path, iface, method, params, inv):
        if method == "RegisterClient":
            self.n += 1
            cpath = "/org/gnome/SessionManager/Client%d" % self.n
            try:
                rid = conn.register_object(cpath, self.cl_info,
                                           self.on_client_method, None, None)
                self.clients[cpath] = rid
            except Exception as e:
                sys.stderr.write("register_object failed: %s\n" % e)
            inv.return_value(GLib.Variant("(o)", (cpath,)))
        elif method == "UnregisterClient":
            cpath = params.unpack()[0]
            rid = self.clients.pop(cpath, None)
            if rid is not None:
                conn.unregister_object(rid)
            inv.return_value(None)
        elif method == "Inhibit":
            self.cookie += 1
            inv.return_value(GLib.Variant("(u)", (self.cookie,)))
        elif method == "Uninhibit" or method in ("Setenv", "InitializationError"):
            inv.return_value(None)
        elif method == "IsInhibited":
            inv.return_value(GLib.Variant("(b)", (False,)))
        elif method in ("GetClients", "GetInhibitors"):
            inv.return_value(GLib.Variant("(ao)", (list(self.clients.keys())
                                                   if method == "GetClients" else [],)))
        elif method == "IsAutostartConditionHandled":
            inv.return_value(GLib.Variant("(b)", (False,)))
        elif method == "CanShutdown":
            inv.return_value(GLib.Variant("(b)", (True,)))
        elif method == "IsSessionRunning":
            inv.return_value(GLib.Variant("(b)", (True,)))
        elif method == "Logout":
            host("exit"); inv.return_value(None)
        elif method == "Shutdown":
            host("poweroff"); inv.return_value(None)
        elif method == "Reboot":
            host("reboot"); inv.return_value(None)
        else:
            inv.return_error_literal("org.gnome.SessionManager.Error",
                                     "unhandled: %s" % method)

    def on_client_method(self, conn, sender, path, iface, method, params, inv):
        # phosh calls EndSessionResponse; we drive teardown host-side, so ack.
        inv.return_value(None)

    def get_prop(self, conn, sender, path, iface, prop):
        if prop == "SessionName":       return GLib.Variant("s", "phosh")
        if prop == "SessionIsActive":   return GLib.Variant("b", True)
        if prop == "InhibitedActions":  return GLib.Variant("u", 0)
        if prop == "Renderer":          return GLib.Variant("s", "")
        return None

    def on_bus(self, conn, name):
        self.conn = conn
        conn.register_object("/org/gnome/SessionManager", self.sm_info,
                             self.on_method, self.get_prop, None)
        self.wake = WakeWatcher(conn)

    def on_acquired(self, conn, name):
        sys.stderr.write("det-session-manager: owns %s\n" % name); sys.stderr.flush()

    def on_lost(self, conn, name):
        sys.stderr.write("det-session-manager: lost/failed name %s\n" % name)
        sys.stderr.flush()

def main():
    sm = SM()
    Gio.bus_own_name(Gio.BusType.SESSION, "org.gnome.SessionManager",
                     Gio.BusNameOwnerFlags.REPLACE, sm.on_bus,
                     sm.on_acquired, sm.on_lost)
    GLib.MainLoop().run()

if __name__ == "__main__":
    main()
EOS
chmod 0755 /usr/local/bin/det-session-manager

echo "== det-console (Ctrl+Alt+F2 emergency terminal) =="
# Companion to the phoc PATCH 3 (build-wlroots-phoc.sh): Ctrl+Alt+F2-F12
# calls det-console <vt> instead of the no-op VT switch (no fbcon on this
# device). Opens a fullscreen foot terminal. Requires an external keyboard
# (the on-screen squeekboard can't produce Ctrl+Alt+F*).
cat > /usr/local/bin/det-console <<'EOS'
#!/bin/sh
# Determination console — fullscreen terminal on Ctrl+Alt+F<n>.
# Called by phoc's patched VT-switch handler (keyboard.c PATCH 3).
# Inherit the Wayland env from whoever invoked phoc (desktop-on 5e). phoc runs
# as melissa (uid 1000), so its VT-switch handler spawns us as melissa too.
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VT="${1:-2}"
exec foot --fullscreen --title "Console VT${VT}" -- /bin/bash -l
EOS
chmod 0755 /usr/local/bin/det-console

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

echo "== battery translator (det-battery) =="
# The OP7 'battery' power_supply node reports a stuck/garbage capacity on this
# kernel (frozen charge_counter, bogus 41°C temp) — that's what UPower/phosh
# read, so the Linux battery shows ~1%. The REAL gauge is the 'bms' node
# (type=BMS, which UPower ignores). This daemon shadows battery/capacity with
# the live bms value via a bind-mount that lives ONLY in the guest mount
# namespace — Android's own (correct) reading is never touched.
cat > /usr/local/sbin/det-battery <<'EOS'
#!/bin/sh
set -u
BMS=/sys/class/power_supply/bms/capacity
CAP=/run/det-battery-capacity
[ -r "$BMS" ] || { echo "det-battery: bms node not present — nothing to do"; exit 0; }

seed=$(cat "$BMS" 2>/dev/null)
case "$seed" in ''|*[!0-9]*) seed=50 ;; esac
echo "$seed" > "$CAP"
echo "det-battery: shadowing battery/capacity <- bms (seed ${seed})"

# Poll the real gauge and KEEP the shadow bind alive. The bind must be
# re-asserted every pass, not just once: the qpnp-smb5 charger re-enumerates
# its power_supply node on USB plug/unplug, which silently drops the bind and
# drops UPower/phosh back to the stuck raw capacity (found 2026-07-12, the
# "battery shat itself" report). Re-resolve BATT each pass too — the sysfs
# symlink is recreated by the re-enumeration. The bind propagates into
# UPower's private mount namespace because /sys is a shared mount.
while :; do
    c=$(cat "$BMS" 2>/dev/null)
    case "$c" in ''|*[!0-9]*) ;; *) echo "$c" > "$CAP" ;; esac
    BATT=$(readlink -f /sys/class/power_supply/battery 2>/dev/null)
    if [ -n "$BATT" ] && [ -e "$BATT/capacity" ]; then
        mountpoint -q "$BATT/capacity" || mount --bind "$CAP" "$BATT/capacity" 2>/dev/null
    fi
    sleep 15
done
EOS
chmod 0755 /usr/local/sbin/det-battery
cat > /etc/systemd/system/det-battery.service <<EOF
[Unit]
Description=Determination: mirror the real (bms) battery level into UPower's node
After=local-fs.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/det-battery
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now det-battery.service 2>/dev/null && echo "det-battery enabled + started" ||
    echo "note: could not start det-battery.service (will start next boot)"

echo "== done =="
echo "Session manager shim installed: Logout->phone, Shutdown/Reboot->host,"
echo "wake watcher (blank -> next key/touch unblanks; needs setup-input.sh"
echo "rerun to un-quirk KEY_POWER)."
echo "Power menu (Power Off / Restart) + app-grid tiles now drive the host."
echo "Requires the guest to be running under the lxc config that binds"
echo "/mnt/det-control (restart the container / reboot after installing the"
echo "new module if 'det-signal' reports the channel isn't mounted)."
