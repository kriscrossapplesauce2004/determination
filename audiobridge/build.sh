#!/bin/bash
# Cross-build det-audiobridge for Android arm64 (AAudio, API 31).
set -e
NDK="${NDK:-$HOME/android-sdk/ndk/27.2.12479018}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang"
cd "$(dirname "$0")"
"$CC" -O2 -Wall -o det-audiobridge det-audiobridge.c -laaudio -lm
echo "built: $(file det-audiobridge 2>/dev/null || ls -l det-audiobridge)"
