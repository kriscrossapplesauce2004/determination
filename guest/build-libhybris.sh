#!/bin/sh
# Build UPSTREAM libhybris (glibc side) inside the guest, natively on the
# phone. Runs INSIDE the container (e.g. via lxc-attach or the guest shell),
# NOT on the host. Needs network + the Droidian apt repo already configured
# (guest/setup-guest.sh).
#
# WHY UPSTREAM, NOT DROIDIAN'S DEB: Droidian's libhybris fork last merged
# upstream in Aug 2024 and its newest deb (droidian1, Dec 2025) is only a
# header rebuild. That code predates Android 15/16 support and CRASHES on
# this device (Android 16 / API 36): bionic reads a private TLS slot the
# libhybris 'q' linker never set up -> SIGSEGV the instant bionic runs.
# Upstream master added real A16 support (PR #609, hwc2 A15/16, sdk-version
# fix, linker path-order fix). Built from master, test_hwcomposer correctly
# detects "Android SDK version 36", loads the linker, and runs bionic code
# past the old crash. (Proven 2026-07-04.)
#
# WHAT THIS DOES NOT DO: the android-side HWC2 adaptation
# (libhwc2_compat_layer.so, from the repo's compat/hwc2/ Android.mk, our
# device = the HidlComposerHal variant for composer@2.1-2.4) is a SEPARATE
# bionic build and is NOT produced here. Without it test_hwcomposer stops at
# "libhwc2_compat_layer.so not found". That is the remaining porting work.
set -eu

SRC="${SRC:-/root/build/libhybris}"
JOBS="$(nproc)"
export TMPDIR=/tmp   # Android leaks TMPDIR=/data/local/tmp into the guest;
mkdir -p /tmp        # config.guess needs a writable one.

# Build deps. android-headers-30 provides the pkg-config 'android-headers'
# module and hardware/hwcomposer2.h (gates the hwc2 path). Newer header
# packages don't exist in the repo; 30 is fine, the A16 support is runtime.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git build-essential automake libtool pkg-config \
    android-headers-30 libwayland-dev wayland-protocols libwayland-egl-backend-dev

mkdir -p "$(dirname "$SRC")"
[ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/libhybris/libhybris.git "$SRC"
cd "$SRC/hybris"

[ -x configure ] || NOCONFIGURE=1 ./autogen.sh
# --enable-arch=arm64 is REQUIRED: the default is 32-bit arm, which builds a
# linker that can't load the device's 64-bit bionic (gives /system/lib paths
# instead of lib64).
[ -f Makefile ] || ./configure \
    --build=aarch64-linux-gnu --enable-arch=arm64 \
    --with-android-headers=/usr/include/android \
    --with-default-egl-platform=hwcomposer \
    --enable-wayland --enable-adreno-quirks --enable-experimental

# The tests subdir fails to build test_audio (strdup decl missing in the
# android audio.h) — irrelevant, and it is the LAST subdir, so the libraries
# and the linker are already built/installed before it aborts. Ignore it.
make -j"$JOBS" || true
make install || true    # -> /usr/local; installs the q/mm/n/o linkers to
                        # /usr/local/lib/libhybris/linker/ (HYBRIS_LINKER_DIR
                        # default) and the glibc-side libs to /usr/local/lib.
ldconfig || true

cat <<'NOTE'
libhybris (glibc side) built and installed to /usr/local.
Run hybris programs with:
  LD_LIBRARY_PATH=/usr/local/lib
  HYBRIS_LD_LIBRARY_PATH=/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
  EGL_PLATFORM=hwcomposer
Still TODO for the display gate: build libhwc2_compat_layer.so from the
libhybris repo's compat/hwc2/ (Android.mk, bionic toolchain, HidlComposerHal
for this device's composer@2.1-2.4).
NOTE
