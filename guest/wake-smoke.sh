#!/bin/sh
# Determination wake-path smoke test — run INSIDE the guest, in DESKTOP MODE,
# while phosh is up. Exercises the full blank/unblank round trip over DBus
# (org.gnome.ScreenSaver.SetActive true -> false), i.e. exactly the path the
# power button takes: phosh -> wlr-output-power -> phoc hwcomposer
# set_power_mode OFF/ON. No button press needed — this isolates the
# compositor re-enable from the input-side wake (det-session-manager's
# active watch), so a failure here is a phoc/hwcomposer bug, not a watcher
# bug. PANEL GOES BLACK for ~BLANK_SECS seconds mid-run: expected.
#
# Usage: wake-smoke.sh [blank-secs]   (default 5)
set -u
BLANK_SECS=${1:-5}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export XDG_RUNTIME_DIR=/run/user/0

PHOSH_PID=$(pgrep -x phosh | head -1)
[ -n "$PHOSH_PID" ] || { echo "FAIL: phosh not running (desktop mode on?)"; exit 1; }

# The session bus is private to desktop-on's dbus-run-session — steal its
# address from phosh's environ.
ADDR=$(tr '\0' '\n' < "/proc/$PHOSH_PID/environ" |
       sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
[ -n "$ADDR" ] || { echo "FAIL: phosh has no DBUS_SESSION_BUS_ADDRESS"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS="$ADDR"
echo "phosh pid $PHOSH_PID, session bus $ADDR"

python3 - "$BLANK_SECS" <<'EOF'
import sys, time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

blank_secs = int(sys.argv[1])
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
SS = "org.gnome.ScreenSaver"
SSP = "/org/gnome/ScreenSaver"

def ss(method, params=None):
    return bus.call_sync(SS, SSP, SS, method, params, None,
                         Gio.DBusCallFlags.NONE, 5000, None)

def get_active():
    return ss("GetActive").unpack()[0]

fails = 0
def check(name, cond):
    global fails
    print("%s: %s" % ("PASS" if cond else "FAIL", name))
    if not cond:
        fails += 1

check("screensaver initially inactive", get_active() is False)

print("-> SetActive(true) — panel should BLANK now")
ss("SetActive", GLib.Variant("(b)", (True,)))
time.sleep(1.5)  # phosh marks active only once phoc confirms the power mode
check("screensaver reports active after blank", get_active() is True)

time.sleep(blank_secs)

print("-> SetActive(false) — panel should COME BACK now")
ss("SetActive", GLib.Variant("(b)", (False,)))
time.sleep(1.5)
check("screensaver reports inactive after wake", get_active() is False)

print("WAKE-SMOKE %s (visual check: did the panel visibly come back lit?)"
      % ("OK" if fails == 0 else "FAILED"))
sys.exit(1 if fails else 0)
EOF
