#!/bin/sh
# Build the exact KWin 6.3.6 virtual-QPainter frame export used by the
# Determination DP bridge. This patches only libkwin's virtual backend.
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
# The virtual QPainter backend does not call GBM, but libkwin contains the DRM
# backend too. Make any unavoidable GBM linkage resolve to minigbm, never Mesa.
export PKG_CONFIG_PATH=/opt/minigbm/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig
SOURCE=${1:-/usr/src/kwin-6.3.6}
PATCH=${2:-/root/kwin-6.3.6-virtual-framebuffer.patch}
HEADER=${3:-/root/framebuffer-protocol.h}
BUILD=${4:-/var/tmp/determination-kwin-build}

[ -f "$SOURCE/src/backends/virtual/virtual_qpainter_backend.cpp" ] || {
    echo "FATAL: KWin 6.3.6 source missing at $SOURCE" >&2
    exit 2
}

install -D -m 0644 "$HEADER" \
    /usr/local/include/determination/framebuffer-protocol.h

if ! grep -q DETERMINATION_FRAMEBUFFER \
        "$SOURCE/src/backends/virtual/virtual_qpainter_backend.cpp"; then
    patch -d "$SOURCE" -p1 < "$PATCH"
fi

cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -Dgbm_LIBRARY=/opt/minigbm/lib/libgbm.so \
    -Dgbm_INCLUDE_DIR=/opt/minigbm/include \
    -DBUILD_TESTING=OFF \
    -DKWIN_BUILD_KCMS=OFF \
    -DKWIN_BUILD_X11=OFF \
    -DKWIN_BUILD_X11_BACKEND=OFF \
    -DKWIN_BUILD_NOTIFICATIONS=OFF \
    -DKWIN_BUILD_SCREENLOCKER=OFF \
    -DKWIN_BUILD_RUNNERS=OFF \
    -DKWIN_BUILD_ACTIVITIES=OFF \
    -DKWIN_BUILD_EIS=OFF
cmake --build "$BUILD" --target kwin -- -j1

echo "Built patched KWin. Install only after reviewing the output in $BUILD."
