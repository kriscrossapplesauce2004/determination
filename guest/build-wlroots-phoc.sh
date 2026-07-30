#!/bin/sh
# Determination §3 finish: build the REAL guest compositor --- phoc 0.47 on the
# droidian wlroots fork's hwcomposer backend --- inside the trixie guest,
# against OUR upstream libhybris in /usr/local (guest/build-libhybris.sh).
# Run INSIDE the container as root. Non-destructive/idempotent-ish: safe to
# re-run; clones are wiped and re-fetched.
#
# WHY THESE SOURCES (2026-07-06):
#  - Stock Debian sway/wlroots is DRM/KMS-only and cannot drive this panel.
#  - droidian/wlroots branch feature/next/backport-0.18 is their LIVE line
#    (default branch, pushed 2026-05): wlroots 0.17.4 + backported 0.18
#    APIs + the hwcomposer backend + an "android" renderer.
#  - sway is a DEAD END against this fork: sway 1.9 wants pure 0.17 API
#    (fails on the backported 0.18 presentation/transform APIs), sway 1.10
#    wants real 0.18 (version pin rejects 0.17.4). Don't retry.
#  - droidian/phoc branch group/102/keypad-slide-lights (phoc 0.47, their
#    droidian-102 shipping line) pins system wlroots >=0.17 <0.18 --- an
#    exact match for the fork. It REQUIRES xwayland-enabled wlroots
#    (unguarded includes and struct fields).
#  - libdroid is a build-dep of the wlroots hwcomposer backend. It is
#    glibc-native (gio + libgbinder, talks to HALs over binder directly, no
#    libhybris linkage) --- but droidian's BINARY package would drag in their
#    stale TLS-broken libhybris debs, so it's built from source too.
#
# RUNTIME GOTCHAS THE OUTPUT DEPENDS ON (encoded in toggle/desktop-on):
#  - LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu is
#    MANDATORY: droidian z4 libhybris debs still sit in /lib/aarch64-linux-gnu
#    and win ld.so.conf ordering otherwise (aarch64-linux-gnu.conf sorts
#    before libc.conf).
#  - phoc must NOT use -E/--exec: glib child-watch is broken on the
#    pidfd-less 4.14 kernel (waitid(P_PIDFD) EINVAL) and phoc tears the
#    session down thinking the child died. Launch clients separately.
#  - The container needs lxc.pty.max (guest/lxc/config) or terminals get
#    "failed to open PTY" (inherited devpts has ptmxmode=000).
#  - /etc/phoc.ini sets output scale 3 --- default scale 1 is unreadable at
#    403dpi (guest/phoc.ini).
#  - SDM DSPP-dims new composer clients to black: our wlroots patch below
#    calls hwc2_compat_display_set_brightness(1.0) after power-on.
#  - Input (§4): WLR_BACKENDS=hwcomposer,libinput + LIBSEAT_BACKEND=seatd,
#    plus the udev-db faker + seatd from guest/setup-input.sh (udevd can't
#    run in the container --- ro /sys). PATCH 2 below adds the EVIOCGRAB
#    handoff; desktop-on kills evgrab once phoc's socket is up.
set -e
. "$(dirname "$0")/sources.lock"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TMPDIR=/tmp
export PKG_CONFIG_PATH=/usr/local/lib/aarch64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig
export CFLAGS=-I/usr/local/include LDFLAGS=-L/usr/local/lib
B=/root/build
mkdir -p "$B"

echo "== deps (apt) =="
# wlroots core + sway-era leftovers + phoc/GNOME bits + xwayland (phoc hard
# requirement) + drm backend bits (libdisplay-info/liftoff) + runtime
# (foot terminal, a font --- foot fails without one --- grim for screenshots,
# dbus quiets phoc's session warnings).
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    meson ninja-build git ca-certificates pkg-config gettext \
    wayland-protocols libwayland-dev libdrm-dev libgbm-dev libinput-dev \
    libxkbcommon-dev libpixman-1-dev libseat-dev libudev-dev hwdata \
    libegl-dev libgles-dev glslang-tools libevdev-dev \
    libgbinder-dev libglib2.0-dev libgirepository1.0-dev libsystemd-dev \
    systemd-dev \
    libgnome-desktop-3-dev gsettings-desktop-schemas mutter-common \
    libgmobile-dev libjson-glib-dev \
    xwayland libxcb1-dev libxcb-composite0-dev libxcb-render0-dev \
    libxcb-res0-dev libxcb-xfixes0-dev libxcb-icccm4-dev libxcb-ewmh-dev \
    libxcb-xinput-dev libxcb-dri3-dev libxcb-present-dev libxcb-shm0-dev \
    libdisplay-info-dev libliftoff-dev \
    foot fonts-dejavu-core dbus grim

echo "== libhybris prereq check =="
# android-headers comes from the droidian repo (installed by
# build-libhybris.sh's flow); the SetBufferCount + set_brightness patches
# must already be in the installed libhybris (build-libhybris.sh).
pkg-config --exists 'android-headers >= 9.0.0' || {
    echo "FATAL: android-headers pkg-config missing (install android-headers-30)"; exit 1; }
nm -D /usr/local/lib/libhybris-hwcomposerwindow.so | grep -q HWCNativeWindowSetBufferCount || {
    echo "FATAL: libhybris lacks HWCNativeWindowSetBufferCount --- re-run guest/build-libhybris.sh"; exit 1; }
nm -D /usr/local/lib/libhwc2.so.1 | grep -q hwc2_compat_display_set_brightness || {
    echo "FATAL: libhwc2 lacks set_brightness wrapper --- re-run guest/build-libhybris.sh"; exit 1; }
grep -q hwc2_compat_display_set_brightness /usr/local/include/hybris/hwc2/hwc2_compatibility_layer.h || {
    echo "FATAL: installed hwc2 header lacks set_brightness decl --- re-run guest/build-libhybris.sh"; exit 1; }
# GPU app buffers: clients reach the GPU through hybris' wayland EGL
# platform (android_wlegl); wlroots' android renderer serves the other
# half. Without this plugin every app silently falls back to wl_shm.
[ -f /usr/local/lib/libhybris/eglplatform_wayland.so ] || {
    echo "FATAL: libhybris wayland EGL platform missing --- re-run guest/build-libhybris.sh (--enable-wayland)"; exit 1; }

echo "== libdroid (from source --- do NOT apt install libdroid-dev) =="
cd "$B" && rm -rf libdroid
git clone --depth 1 -b droidian "$LIBDROID_REPO"
cd libdroid
[ "$(git rev-parse HEAD)" = "$LIBDROID_COMMIT" ] || { echo "FATAL: libdroid pin mismatch" >&2; exit 1; }
meson setup build --prefix=/usr/local -Dbuildtype=release
ninja -C build && ninja -C build install

echo "== wlroots (droidian fork, hwcomposer backend) =="
cd "$B" && rm -rf wlroots
git clone --depth 1 -b feature/next/backport-0.18 "$WLROOTS_REPO"
cd wlroots
[ "$(git rev-parse HEAD)" = "$WLROOTS_COMMIT" ] || { echo "FATAL: wlroots pin mismatch" >&2; exit 1; }

# PATCH (upstream-able to droidian): SDM (qcom sm8150) starts every NEW
# composer client at per-client brightness 0 and DSPP-dims its output to
# pure black while validate/present succeed (determination b182d86). Call
# setDisplayBrightness(1.0) once after successful power-on. Idempotent.
F=backend/hwcomposer/hwcomposer2.c
grep -q hwc2_compat_display_set_brightness "$F" || sed -i \
's|\t\tif (enable \&\& change_backlight \&\&|\t\t/* Determination: SDM inits new composer clients at brightness 0 and\n\t\t * DSPP-dims their output to black; one set_brightness after\n\t\t * power-on fixes it (see determination b182d86). */\n\t\tif (enable)\n\t\t\thwc2_compat_display_set_brightness(hwc2_output->hwc2_display, 1.0f);\n\n\t\tif (enable \&\& change_backlight \&\&|' "$F"
grep -q hwc2_compat_display_set_brightness "$F" || { echo "FATAL: brightness patch anchor missing"; exit 1; }

# PATCH 2 (Determination §4, 2026-07-06): EVIOCGRAB handoff in the libinput
# backend. Android's EventHub (inside system_server) keeps every
# /dev/input/event* open non-exclusively --- without a grab, events reach
# BOTH stacks. The Android-side evgrab holds the grab through the SF stop;
# this patch makes the guest take its own grab (dup'd fd + detached
# 100ms-retry thread) the moment libinput opens each node, so desktop-on
# can kill evgrab once phoc is up and the guest acquires within a tick.
# Grabs live on the open file description, so they vanish with phoc.
python3 - <<'PYEOF'
import pathlib, sys

p = pathlib.Path('backend/libinput/backend.c')
s = p.read_text()
if 'dos_grab_evdev' in s:
    print('grab patch: already applied')
    sys.exit(0)

inc_anchor = '#include "util/env.h"\n'
assert inc_anchor in s, 'include anchor missing'
s = s.replace(inc_anchor, inc_anchor + (
    '\n'
    '/* Determination §4 input handoff */\n'
    '#include <errno.h>\n'
    '#include <linux/input.h>\n'
    '#include <pthread.h>\n'
    '#include <stdint.h>\n'
    '#include <string.h>\n'
    '#include <sys/ioctl.h>\n'
    '#include <time.h>\n'
    '#include <unistd.h>\n'
), 1)

helper = '''\
/* Determination §4: Android's EventHub (inside system_server) keeps
 * /dev/input/event* open non-exclusively --- without EVIOCGRAB every event
 * is delivered to BOTH stacks (double input). During the handoff the
 * Android-side evgrab daemon still holds the grab, so retry from a
 * detached thread until desktop-on kills evgrab. The grab is taken on a
 * dup'd fd: grabs belong to the open file description, which libinput's
 * fd shares, so the grab lives exactly as long as libinput's device. */
static void *dos_grab_thread(void *arg) {
\tint fd = (int)(intptr_t)arg;
\tstruct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
\t/* 10min window, not 30s: a slow phoc bring-up outlived the first
\t * version and left the session grabless (2026-07-06). */
\tfor (int i = 0; i < 6000; i++) {
\t\tif (ioctl(fd, EVIOCGRAB, (void *)1) == 0) {
\t\t\tfprintf(stderr, "Determination: EVIOCGRAB acquired (fd %d)\\n", fd);
\t\t\tbreak;
\t\t}
\t\tif (errno != EBUSY) {
\t\t\tfprintf(stderr, "Determination: EVIOCGRAB failed (fd %d): %s\\n",
\t\t\t\tfd, strerror(errno));
\t\t\tbreak;
\t\t}
\t\tnanosleep(&ts, NULL);
\t}
\tclose(fd);
\treturn NULL;
}

static void dos_grab_evdev(const char *path, int fd) {
\tif (strncmp(path, "/dev/input/event", 16) != 0) {
\t\treturn;
\t}
\tint gfd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
\tif (gfd < 0) {
\t\treturn;
\t}
\tpthread_t t;
\tpthread_attr_t attr;
\tpthread_attr_init(&attr);
\tpthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
\tif (pthread_create(&t, &attr, dos_grab_thread, (void *)(intptr_t)gfd) != 0) {
\t\tclose(gfd);
\t}
\tpthread_attr_destroy(&attr);
}

'''
fn_anchor = 'static int libinput_open_restricted(const char *path,'
assert fn_anchor in s, 'open_restricted anchor missing'
s = s.replace(fn_anchor, helper + fn_anchor, 1)

droidian = '\treturn open(path, O_RDWR | O_CLOEXEC | O_NONBLOCK);'
assert droidian in s, 'droidian-branch anchor missing'
s = s.replace(droidian, (
    '\tint fd = open(path, O_RDWR | O_CLOEXEC | O_NONBLOCK);\n'
    '\tif (fd >= 0) {\n'
    '\t\tdos_grab_evdev(path, fd);\n'
    '\t}\n'
    '\treturn fd;'
), 1)

sess = '\treturn dev->fd;\n#endif // WLR_HAS_DROIDIAN_EXTENSIONS\n}'
assert sess in s, 'session-branch anchor missing'
s = s.replace(sess, (
    '\tdos_grab_evdev(path, dev->fd);\n'
    '\treturn dev->fd;\n'
    '#endif // WLR_HAS_DROIDIAN_EXTENSIONS\n}'
), 1)

p.write_text(s)
print('grab patch: applied')
PYEOF
grep -q dos_grab_evdev backend/libinput/backend.c || { echo "FATAL: grab patch failed"; exit 1; }

# drm backend + xwayland are NOT optional: phoc group/102 has unguarded
# wlr/xwayland.h includes and calls drm-backend symbols.
meson setup build --prefix=/usr/local -Dbuildtype=release \
    -Dbackends=drm,libinput,hwcomposer -Drenderers=gles2,android \
    -Dxwayland=enabled -Dexamples=false
ninja -C build && ninja -C build install
ldconfig

echo "== phoc (droidian group/102) =="
cd "$B" && rm -rf phoc
git clone --depth 1 -b group/102/keypad-slide-lights "$PHOC_REPO"
cd phoc
[ "$(git rev-parse HEAD)" = "$PHOC_COMMIT" ] || { echo "FATAL: phoc pin mismatch" >&2; exit 1; }

# PATCH 3 (Determination): Ctrl+Alt+F2-F12 spawns a console terminal instead
# of the no-op wlr_session_change_vt (no real VTs --- CONFIG_FRAMEBUFFER_CONSOLE
# is off because it fights SF for the panel). VT 1 is left as-is (phosh). The
# helper /usr/local/bin/det-console opens a fullscreen foot terminal; it can
# also be a dispatcher for VT-specific sessions later. Works from any external
# keyboard; evdev-level is blocked by our EVIOCGRAB, so compositor-level is the
# only viable hook. See guest/setup-controls.sh for the det-console script.
F=src/keyboard.c
grep -q 'det-console' "$F" || python3 - "$F" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = '''\
  if (keysym >= XKB_KEY_XF86Switch_VT_1 && keysym <= XKB_KEY_XF86Switch_VT_12) {
    struct wlr_session *session = phoc_server_get_session (server);

    if (session) {
      unsigned vt = keysym - XKB_KEY_XF86Switch_VT_1 + 1;
      wlr_session_change_vt (session, vt);
    }

    return true;
  }'''
new = '''\
  if (keysym >= XKB_KEY_XF86Switch_VT_1 && keysym <= XKB_KEY_XF86Switch_VT_12) {
    unsigned vt = keysym - XKB_KEY_XF86Switch_VT_1 + 1;
    if (vt >= 2) {
      /* Determination: no real VTs (fbcon off); spawn a console terminal.
       * Fork+exec so the compositor never blocks on the child. */
      char cmd[64];
      snprintf (cmd, sizeof(cmd), "/usr/local/bin/det-console %u", vt);
      g_spawn_command_line_async (cmd, NULL);
    } else {
      struct wlr_session *session = phoc_server_get_session (server);
      if (session)
        wlr_session_change_vt (session, vt);
    }
    return true;
  }'''
assert old in s, 'VT switch anchor missing in keyboard.c'
s = s.replace(old, new, 1)
p.write_text(s)
print('PATCH 3 (det-console VT switch): applied')
PYEOF
grep -q 'det-console' "$F" || { echo "FATAL: det-console VT patch failed"; exit 1; }

meson setup build --prefix=/usr/local -Dbuildtype=release \
    -Dembed-wlroots=disabled -Dman=false -Dxwayland=enabled
ninja -C build && ninja -C build install
ldconfig

echo "== sanity =="
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu
ldd /usr/local/lib/aarch64-linux-gnu/libwlroots.so.12a | grep -E 'EGL|hwc2' | grep -q /usr/local/lib || {
    echo "WARN: hybris libs not resolving to /usr/local --- check LD_LIBRARY_PATH at runtime"; }
/usr/local/bin/phoc --version
echo "BUILD-WLROOTS-PHOC-OK --- run via toggle/desktop-on (never phoc -E)"
