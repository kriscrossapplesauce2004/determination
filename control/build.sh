#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CONTROL="$ROOT/control"
MODE=${1:-all}
NDK=${NDK:-/home/melissa/android-sdk/ndk/27.2.12479018}

build_host() {
    cmake -S "$CONTROL" -B "$CONTROL/build/host" -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build "$CONTROL/build/host"
    ctest --test-dir "$CONTROL/build/host" --output-on-failure
}

build_android() {
    TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
    [ -f "$TOOLCHAIN" ] || {
        echo "Android NDK toolchain not found: $TOOLCHAIN" >&2
        exit 1
    }
    cmake -S "$CONTROL" -B "$CONTROL/build/android-arm64" -G Ninja \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-29 \
        -DANDROID_STL=c++_static
    cmake --build "$CONTROL/build/android-arm64"
}

case "$MODE" in
    host) build_host ;;
    android) build_android ;;
    all) build_host; build_android ;;
    clean)
        rm -rf "$CONTROL/build"
        ;;
    *)
        echo "usage: $0 [host|android|all|clean]" >&2
        exit 2
        ;;
esac

