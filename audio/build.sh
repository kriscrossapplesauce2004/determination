#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
AUDIO="$ROOT/audio"
MODE=${1:-all}
NDK=${NDK:-/home/melissa/android-sdk/ndk/27.2.12479018}

build_host() {
    cmake -S "$AUDIO" -B "$AUDIO/build/host" -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build "$AUDIO/build/host"
    ctest --test-dir "$AUDIO/build/host" --output-on-failure
}

build_android() {
    toolchain="$NDK/build/cmake/android.toolchain.cmake"
    [ -f "$toolchain" ] || {
        echo "Android NDK toolchain not found: $toolchain" >&2
        exit 1
    }
    cmake -S "$AUDIO" -B "$AUDIO/build/android-arm64" -G Ninja \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-29 \
        -DANDROID_STL=c++_static \
        -DBUILD_TESTING=OFF
    cmake --build "$AUDIO/build/android-arm64"
}

build_guest() {
    command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 || {
        echo "aarch64-linux-gnu-g++ is required for the Debian guest build" >&2
        exit 1
    }
    cmake -S "$AUDIO" -B "$AUDIO/build/guest-arm64" -G Ninja \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DBUILD_TESTING=OFF
    cmake --build "$AUDIO/build/guest-arm64"
}

case "$MODE" in
    host) build_host ;;
    android) build_android ;;
    guest) build_guest ;;
    all) build_host; build_android; build_guest ;;
    clean) rm -rf "$AUDIO/build" ;;
    *) echo "usage: $0 [host|android|guest|all|clean]" >&2; exit 2 ;;
esac
