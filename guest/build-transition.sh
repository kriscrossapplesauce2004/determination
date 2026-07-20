#!/bin/bash
# Build the finite HWC transition client inside the running guest.
#
# Prerequisite: guest/build-libhybris.sh has completed, leaving its build tree
# at /root/build/libhybris/hybris. Copy det-transition.cpp to /root first, then
# run this script through lxc-attach in phone mode.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TMPDIR=/tmp

SRC=${1:-/root/det-transition.cpp}
HYBRIS=/root/build/libhybris/hybris
TESTS=$HYBRIS/tests

[ -r "$SRC" ] || { echo "FATAL: missing source: $SRC" >&2; exit 1; }
[ -r "$TESTS/test_common-test_common.o" ] && COMMON=$TESTS/test_common-test_common.o || \
    COMMON=$TESTS/test_hwcomposer-test_common.o
[ -r "$COMMON" ] || { echo "FATAL: libhybris test_common object missing; rebuild libhybris" >&2; exit 1; }

cd "$TESTS"

CXXFLAGS=(
    -DHAVE_CONFIG_H -I. -I..
    -I/usr/include/android -I/usr/include/android/libnfc-nxp
    -I../include -I../common -I../platforms/common
    -I../egl/platforms/common -I../egl/platforms/hwcomposer -I../libsync
    -DUSE_HWCOMPOSER=1 -DHAS_HWCOMPOSER2_HEADERS=1
    -std=gnu++17 -O2 -Wall -Wextra -Werror
)

g++ "${CXXFLAGS[@]}" -c "$SRC" -o det-transition-main.o

/bin/bash ../libtool --tag=CXX --mode=link g++ "${CXXFLAGS[@]}" \
    -o det-transition det-transition-main.o "$COMMON" -lm \
    ../common/libhybris-common.la \
    ../platforms/common/libhybris-platformcommon.la \
    ../egl/platforms/common/libhybris-eglplatformcommon.la \
    ../egl/libEGL.la ../glesv2/libGLESv2.la ../hardware/libhardware.la \
    ../hwc2/libhwc2.la ../libsync/libsync.la \
    ../egl/platforms/hwcomposer/libhybris-hwcomposerwindow.la

install -m 0755 .libs/det-transition /usr/local/bin/det-transition
echo "Installed /usr/local/bin/det-transition"
