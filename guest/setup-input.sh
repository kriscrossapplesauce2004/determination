#!/bin/sh
# Determination §4 guest-side input handoff + mobile shell — one script, all
# gotchas encoded. Run INSIDE the container as root. Idempotent.
#
# WHAT THIS SETS UP (2026-07-06):
#  - phosh 0.46 + squeekboard 1.43 from trixie as the real mobile session
#    (Debian's phosh dep pulls Debian's phoc/wlroots — harmless, we run
#    /usr/local/bin/phoc with LD_LIBRARY_PATH=/usr/local/... which wins).
#  - seatd: wlroots' libinput backend (droidian-extensions OFF in our build)
#    requires a wlr_session via libseat; seatd is the no-logind-session
#    backend. Debian's libseat tries seatd first when the socket exists,
#    but desktop-on still exports LIBSEAT_BACKEND=seatd to be explicit.
#  - det-input-udevdb: hand-written /run/udev/data entries. systemd-udevd
#    NEVER runs in this container (ConditionPathIsReadWrite=/sys fails —
#    the container's /sys is read-only), so libinput's udev backend sees no
#    ID_INPUT_* properties and silently ignores every device. The hardware
#    is static, so generating the db once per boot from udevadm's input_id
#    builtin (which works daemon-less) is sufficient. Verified mapping on
#    guacamoleb: event1 = "touchpanel" -> ID_INPUT_TOUCHSCREEN=1.
#  - det-pidfd-shim.so: THE glib child-watch fix. This 4.14 kernel
#    BACKPORTS pidfd_open (syscall 434 returns a real fd — probed
#    2026-07-06) but NOT waitid(P_PIDFD), which returns EINVAL. glib sees
#    pidfd_open succeed, commits to the pidfd path, then child-watch
#    dispatch dies on waitid — this is the real mechanism behind the
#    "never phoc -E" rule and would break phosh's app launching. The shim
#    interposes syscall()/pidfd_open() to return ENOSYS so glib takes its
#    SIGCHLD fallback. LD_PRELOAD it into anything glib-spawn-based
#    (desktop-on does this for the phosh session and phoc).
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TMPDIR=/tmp

echo "== apt: phosh + squeekboard + input tools =="
# Self-repair: adb/USB drops mid-run kill apt via SIGHUP and can leave dpkg
# interrupted (happened 2026-07-06 when the phone's battery died mid-install).
dpkg --configure -a 2>/dev/null || true
apt-get update -qq
# xkb-data: libxkbcommon finds no keymaps without it (we install with
# --no-install-recommends everywhere); fonts-cantarell: phosh's UI font.
# gnome-settings-daemon-common: phosh ABORTS (fatal GLib-GIO-ERROR) without
# the org.gnome.settings-daemon.* schemas — it's only in Recommends
# (found 2026-07-06: the "blinking compositor" crash loop on first light).
# adwaita-icon-theme: squeekboard renders without its key icons otherwise.
apt-get install -y -qq --no-install-recommends \
    phosh squeekboard libinput-tools xkb-data fonts-cantarell \
    gnome-settings-daemon-common adwaita-icon-theme

echo "== seatd =="
systemctl enable --now seatd
systemctl --no-pager --quiet is-active seatd || { echo "FATAL: seatd not active"; exit 1; }

echo "== det-input-udevdb =="
cat > /usr/local/sbin/det-input-udevdb <<'EOF'
#!/bin/sh
# Determination: hand-write /run/udev/data entries for input event nodes so
# libinput's udev backend accepts devices WITHOUT a running udevd (udevd is
# condition-blocked in this container: /sys is read-only). /run is tmpfs —
# desktop-on re-runs this before each phoc launch. Only devices input_id
# actually classifies get an entry; the rest stay invisible to libinput.
set -e
mkdir -p /run/udev/data
for ev in /sys/class/input/event*; do
    [ -e "$ev" ] || continue
    props=$(udevadm test-builtin input_id "$ev" 2>/dev/null | grep '^ID_' || true)
    [ -n "$props" ] || continue
    printf '%s\n' "$props" | sed 's/^/E:/' > "/run/udev/data/c$(cat "$ev/dev")"
done
EOF
chmod 755 /usr/local/sbin/det-input-udevdb
/usr/local/sbin/det-input-udevdb
echo "udev db entries:"; grep -l ID_INPUT /run/udev/data/c13:* | while read -r f; do
    echo "  $f: $(tr '\n' ' ' < "$f")"
done

echo "== libinput quirk: touchpanel bogus axes =="
# The OnePlus touchpanel driver advertises ABS_MT_WIDTH_MAJOR and
# ABS_MT_PRESSURE with min==max==0; libinput hard-rejects the whole device
# ("kernel bug: device has min == max on ABS_MT_WIDTH_MAJOR", found
# 2026-07-06). Strip the bogus axes via quirk — the good ones are
# POSITION_X 0-1078, POSITION_Y 0-2338, TOUCH_MAJOR, SLOT 0-9, TRACKING_ID.
mkdir -p /etc/libinput
cat > /etc/libinput/local-overrides.quirks <<'EOF'
[OnePlus 7 touchpanel]
MatchName=touchpanel
AttrEventCode=-ABS_MT_WIDTH_MAJOR;-ABS_MT_PRESSURE
EOF
# Power key (history): 2026-07-06..11 KEY_POWER was quirked inert here
# because a blank was permanent — "power button kills it". Root cause was
# NOT the phoc hwcomposer backend: phosh has no internal unblank path at
# all; unblanking is gsd-power's job (ScreenSaver.SetActive(false) on user
# activity) and we run phosh bare. det-session-manager (setup-controls.sh)
# now plays that role, so the quirk is gone: power press blanks via phosh,
# next press/touch wakes via the active watch. The qpnp_pon node stays
# open+grabbed by phoc either way (Android must not see the key).

echo "== det-pidfd-shim =="
cat > /tmp/det-pidfd-shim.c <<'EOF'
/* Determination: this 4.14 kernel backports pidfd_open(434) but NOT
 * waitid(P_PIDFD) (EINVAL) — glib child-watch commits to the pidfd path
 * and dies. Make pidfd_open fail ENOSYS so glib uses its SIGCHLD
 * fallback. Interposes both the raw syscall() route glib uses and the
 * glibc pidfd_open() wrapper for good measure. glibc-world only — the
 * bionic side has its own linker and never sees LD_PRELOAD. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/types.h>

#ifndef __NR_pidfd_open
#define __NR_pidfd_open 434
#endif

long syscall(long number, ...)
{
    long a[6];
    va_list ap;
    va_start(ap, number);
    for (int i = 0; i < 6; i++)
        a[i] = va_arg(ap, long);
    va_end(ap);

    if (number == __NR_pidfd_open) {
        errno = ENOSYS;
        return -1;
    }

    static long (*real)(long, long, long, long, long, long, long);
    if (!real)
        real = (long (*)(long, long, long, long, long, long, long))
            (uintptr_t)dlsym(RTLD_NEXT, "syscall");
    return real(number, a[0], a[1], a[2], a[3], a[4], a[5]);
}

int pidfd_open(pid_t pid, unsigned int flags)
{
    (void)pid; (void)flags;
    errno = ENOSYS;
    return -1;
}
EOF
gcc -shared -fPIC -O2 -o /usr/local/lib/det-pidfd-shim.so /tmp/det-pidfd-shim.c
echo "shim installed: /usr/local/lib/det-pidfd-shim.so"

echo "== phosh binary location (Debian splits wrapper vs binary) =="
dpkg -L phosh | grep -E 'bin/|libexec/' || true

echo "SETUP-INPUT-OK"
