#!/bin/bash
# Build libhwc2_compat_layer.so (+ direct_hwc2_test) for guacamoleb, the
# bionic-side HWC2 adaptation layer that libhybris' glibc-side libhwc2.so
# android_dlopen()s. This is the per-Android-version porting work Droidian
# ships in adaptation-<device>; nobody has done it for an Android 16 base,
# so we cross-compile it standalone on the host:
#
#   sources   libhybris master compat/hwc2 (PR #609 added A15/A16 support)
#   toolchain Android NDK r27c (clang, bionic sysroot)
#   headers   AOSP android-16.0.0_r4 gitiles archives (frameworks/native,
#             system/core, libbase, libhidl, libfmq, logging, libhardware,
#             hardware/interfaces graphics+common+drm)
#             + HIDL headers generated with Debian's hidl-gen (frozen
#               interfaces -> codegen version drift is bounded)
#             + composer3 AIDL NDK headers generated with build-tools' aidl
#   link      real /system/lib64 libs pulled from the device; the compat
#             layer must match the RUNNING Android's ABI, which is why
#             ANDROID_VERSION_MAJOR=16 and why prebuilts from halium-9/10
#             ports can't work here (libhwbinder/libhidltransport are gone
#             post-R, composer3-V4-ndk exists, libui/libgui ABI is A16).
#
# Stages (idempotent, cached): fetch gen pull build install. No args = all.
set -eu
cd "$(dirname "$0")"

TAG=android-16.0.0_r4
LIBHYBRIS_REV=7079712a42ea2754adf747e70c6cc75764c8596e
# Release automation must set these from the reviewed input manifest. Refuse
# to fetch opaque archives rather than accepting an unchecked toolchain.
HWC_NDK_SHA256=${HWC_NDK_SHA256:-}
HWC_BUILD_TOOLS_SHA256=${HWC_BUILD_TOOLS_SHA256:-}
TC=../toolchain
NDK=$TC/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin
AIDL=$TC/build-tools/android-16/aidl
HIDLGEN_DIR=$TC/hidl-gen
ADB=${ADB:-$HOME/platform-tools/adb}
CLANGXX="$NDK/clang++ --target=aarch64-linux-android34"
JOBS=$(nproc)

GITILES=https://android.googlesource.com/platform

write_manifest() {
    local output=out/compat-build-manifest.json
    local library first=1
    mkdir -p out
    {
        printf '{"schema":1,"android_tag":"%s","libhybris_revision":"%s",' \
            "$TAG" "$LIBHYBRIS_REV"
        printf '"libraries":['
        for library in out/libhwc2_compat_layer.so out/libui_compat_layer.so; do
            [ -f "$library" ] || continue
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"path":"%s","sha256":"%s","soname":"%s"}' \
                "$library" "$(sha256sum "$library" | awk '{print $1}')" \
                "$(readelf -d "$library" | awk '/SONAME/{gsub(/[\[\]]/, "", $NF); print $NF; exit}')"
        done
        printf '],"device_libraries":['
        first=1
        for library in device-libs/*.so; do
            [ -f "$library" ] || continue
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"path":"%s","sha256":"%s"}' \
                "$library" "$(sha256sum "$library" | awk '{print $1}')"
        done
        printf ']}\n'
    } > "$output"
}

verify_archive() {
    local path=$1 expected=$2
    [ -n "$expected" ] || { echo "missing reviewed SHA-256 for $path" >&2; exit 1; }
    echo "$expected  $path" | sha256sum -c -
}

fetch() {
    mkdir -p aosp "$TC/dl"
    # Toolchain zips (NDK ~650MB; build-tools r36 carries a current `aidl`
    # that understands composer3's frozen AIDL; Debian's aidl is A10-era
    # and does not).
    [ -d "$TC/android-ndk-r27c" ] || { curl -fsSL -o "$TC/dl/ndk.zip" \
        https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
        verify_archive "$TC/dl/ndk.zip" "$HWC_NDK_SHA256"
        unzip -q "$TC/dl/ndk.zip" -d "$TC"; }
    [ -x "$AIDL" ] || { curl -fsSL -o "$TC/dl/bt.zip" \
        https://dl.google.com/android/repository/build-tools_r36_linux.zip
        verify_archive "$TC/dl/bt.zip" "$HWC_BUILD_TOOLS_SHA256"
        mkdir -p "$TC/build-tools" && unzip -q "$TC/dl/bt.zip" -d "$TC/build-tools"; }
    # Debian's hidl-gen (runs on Arch with the Debian android libs beside it).
    if [ ! -x "$HIDLGEN_DIR/usr/bin/hidl-gen" ]; then
        mkdir -p "$HIDLGEN_DIR" && cd "$HIDLGEN_DIR"
        curl -fsSLO "https://ftp.debian.org/debian/pool/main/a/android-platform-system-tools-hidl/hidl-gen_10.0.0+r36-3.1_amd64.deb"
        for p in android-libbase android-liblog android-libboringssl; do
            url=$(curl -fsSL "https://packages.debian.org/trixie/amd64/$p/download" \
                  | grep -oE 'https://ftp\.debian\.org/[^"]*\.deb' | head -1)
            [ -n "$url" ] || { echo "cannot resolve $p package" >&2; exit 1; }
            curl -fsSLO "$url"
        done
        for d in *.deb; do bsdtar xf "$d" data.tar.xz && bsdtar xf data.tar.xz; done
        cd - >/dev/null
    fi
    # AOSP header trees at the tag matching the ROM (BP4A.251205.006).
    aosp() { local repo=$1 sub=${2:-} dest=$3
        [ -d "aosp/$dest" ] && return 0
        mkdir -p "aosp/$dest"
        curl -fsSL "$GITILES/$repo/+archive/refs/tags/$TAG${sub:+/$sub}.tar.gz" \
            | tar xz -C "aosp/$dest"; }
    aosp frameworks/native      ""       frameworks_native
    aosp system/core            ""       system_core
    aosp system/libbase         ""       system_libbase
    aosp system/libhidl         ""       system_libhidl
    aosp system/libfmq          ""       system_libfmq
    aosp system/libhwbinder     ""       system_libhwbinder
    aosp system/logging         ""       system_logging
    aosp hardware/libhardware   ""       hardware_libhardware
    aosp hardware/interfaces    graphics hi_graphics
    aosp hardware/interfaces    common   hi_common
    aosp hardware/interfaces    drm      hi_drm
    aosp hardware/interfaces    media    hi_media
    mkdir -p aosp/hi_root
    ln -sfn ../hi_graphics aosp/hi_root/graphics
    ln -sfn ../hi_common   aosp/hi_root/common
    ln -sfn ../hi_media    aosp/hi_root/media
    # The compat sources themselves.
    [ -d libhybris/.git ] || git clone https://github.com/libhybris/libhybris.git
    git -C libhybris fetch --depth 1 origin "$LIBHYBRIS_REV"
    git -C libhybris checkout --detach "$LIBHYBRIS_REV"
}

gen() {
    # HIDL C++ headers. The interfaces are frozen, so Debian's A10 hidl-gen
    # emits the same API the device's A16-built libs export.
    if [ ! -d gen-hidl ]; then
        mkdir -p gen-hidl
        local HG="$HIDLGEN_DIR/usr/bin/hidl-gen"
        export LD_LIBRARY_PATH="$HIDLGEN_DIR/usr/lib/x86_64-linux-gnu/android"
        for pkg in android.hidl.base@1.0 android.hidl.manager@1.0 \
                   android.hardware.graphics.common@1.0 \
                   android.hardware.graphics.common@1.1 \
                   android.hardware.graphics.common@1.2 \
                   android.hardware.graphics.composer@2.1 \
                   android.hardware.graphics.composer@2.2 \
                   android.hardware.graphics.composer@2.3 \
                   android.hardware.graphics.composer@2.4 \
                   android.hardware.media@1.0 \
                   android.hardware.graphics.bufferqueue@1.0 \
                   android.hardware.graphics.bufferqueue@2.0; do
            "$HG" -o gen-hidl -L c++-headers \
                -r android.hardware:aosp/hi_root \
                -r android.hidl:aosp/system_libhidl/transport "$pkg"
        done
        unset LD_LIBRARY_PATH
    fi
    # composer3 AIDL NDK headers from the frozen aidl_api dirs. V4 matches
    # the device's android.hardware.graphics.composer3-V4-ndk.so.
    if [ ! -d gen-aidl ]; then
        mkdir -p gen-aidl/include gen-aidl/src
        local R1=aosp/hi_graphics/composer/aidl/aidl_api/android.hardware.graphics.composer3/4
        local R2=aosp/hi_graphics/common/aidl/aidl_api/android.hardware.graphics.common/6
        local R3=aosp/hi_common/aidl/aidl_api/android.hardware.common/2
        local R4=aosp/hi_common/fmq/aidl/aidl_api/android.hardware.common.fmq/1
        local R5=aosp/hi_drm/common/aidl/aidl_api/android.hardware.drm.common/1
        local root ver f
        local hash
        for root in "$R5" "$R3" "$R4" "$R2" "$R1"; do
            ver=$(basename "$root")
            hash=$(cat "$root/.hash")
            find "$root" -name '*.aidl' | while read -r f; do
                "$AIDL" --lang=ndk --structured --stability=vintf \
                    --version="$ver" --hash="$hash" \
                    -I "$R1" -I "$R2" -I "$R3" -I "$R4" -I "$R5" \
                    -h gen-aidl/include -o gen-aidl/src "$f"
            done
        done
    fi
    # libgui's own cpp-backend AIDL types (android/gui/*.h pulled in by
    # gui/FrameTimestamps.h etc.). Best-effort: only the enums/parcelables
    # our include chain needs must succeed.
    if [ ! -d gen-gui ]; then
        mkdir -p gen-gui/include gen-gui/src
        find aosp/frameworks_native/libs/gui/android \
             aosp/frameworks_native/libs/gui/aidl -name '*.aidl' \
        | while read -r f; do
            "$AIDL" --lang=cpp -I aosp/frameworks_native/libs/gui \
                -I aosp/frameworks_native/libs/gui/aidl \
                -h gen-gui/include -o gen-gui/src "$f" 2>/dev/null || true
        done
    fi
}

pull() {
    mkdir -p device-libs
    local l
    for l in android.hardware.graphics.composer@2.1 \
             android.hardware.graphics.composer@2.2 \
             android.hardware.graphics.composer@2.3 \
             android.hardware.graphics.composer@2.4 \
             android.hardware.graphics.common@1.0 \
             android.hardware.graphics.common@1.1 \
             android.hardware.graphics.common@1.2 \
             android.hardware.graphics.composer3-V4-ndk \
             android.hardware.graphics.allocator@2.0 \
             libhidlbase libfmq libutils libcutils liblog libbase libsync \
             libui libgui libhardware libbinder libbinder_ndk libc++ \
             libnativewindow libEGL libGLESv2; do
        [ -f "device-libs/$l.so" ] || "$ADB" pull "/system/lib64/$l.so" device-libs/ \
            || { echo "MISSING device lib: $l"; exit 1; }
    done
}

build() {
    local SRCDIR=libhybris/compat/hwc2
    local INC=(
        -I"$SRCDIR" -Ilibhybris/hybris/include
        -Igen-hidl -Igen-aidl/include -Igen-gui/include
        -Iaosp/hi_graphics/composer/2.1/utils/command-buffer/include
        -Iaosp/hi_graphics/composer/2.2/utils/command-buffer/include
        -Iaosp/hi_graphics/composer/2.3/utils/command-buffer/include
        -Iaosp/hi_graphics/composer/2.4/utils/command-buffer/include
        -Iaosp/hi_graphics/composer/aidl/include
        -Iaosp/hi_common/support/include
        -Iaosp/frameworks_native/include
        -Iaosp/frameworks_native/libs/gui/include
        -Iaosp/frameworks_native/libs/ui/include
        -Iaosp/frameworks_native/libs/binder/include
        -Iaosp/frameworks_native/libs/nativewindow/include
        -Iaosp/frameworks_native/libs/nativebase/include
        -Iaosp/frameworks_native/libs/math/include
        -Iaosp/system_core/libcutils/include
        -Iaosp/system_core/libutils/include
        -Iaosp/system_core/libsystem/include
        -Iaosp/system_core/libsync/include
        -Iaosp/system_core/libprocessgroup/include
        -Iaosp/system_logging/liblog/include
        -Iaosp/system_libbase/include
        -Iaosp/system_libhidl/base/include
        -Iaosp/system_libhidl/transport/include
        -Iaosp/system_libhidl/transport/token/1.0/utils/include
        -Iaosp/system_libfmq/include
        -Iaosp/system_libfmq/base
        -Iaosp/hardware_libhardware/include
        -Iaosp/system_libhwbinder/include
        -Iaosp/frameworks_native/libs/binder/ndk/include_platform
        -Iaosp/frameworks_native/libs/binder/ndk/include_cpp
    )
    local CFLAGS=(
        -O2 -fPIC -std=gnu++20 -fno-exceptions -fno-rtti
        -nostdinc++ -Istubs/libcxx
        -DANDROID_VERSION_MAJOR=16 -DANDROID_VERSION_MINOR=0 -DANDROID_VERSION_PATCH=0
        -DGL_GLEXT_PROTOTYPES -UNDEBUG
        -Wno-unused-parameter -Wno-deprecated-declarations
    )
    # The NDK's libc++ headers mangle std into std::__ndk1; the device's
    # platform libs (libc++.so, libhidlbase's std-taking APIs) use std::__1.
    # Same LLVM libc++ and ABI; only the inline namespace differs. Patch
    # a copy of the headers to __1 so our symbols match the platform.
    if [ ! -d stubs/libcxx ]; then
        mkdir -p stubs/libcxx
        cp -r "$NDK/../sysroot/usr/include/c++/v1/." stubs/libcxx/
        sed -i 's/__ndk1/__1/g' stubs/libcxx/__config_site
    fi
    # aconfig flag headers are build-generated in AOSP; the gui headers we
    # pull in only use the macro form. Flags off = pre-flag behavior (64
    # buffer slots etc.), which only sizes this client's caches.
    mkdir -p stubs
    cat > stubs/com_android_graphics_libgui_flags.h <<'EOF'
#pragma once
#define COM_ANDROID_GRAPHICS_LIBGUI_FLAGS(flag) (COM_ANDROID_GRAPHICS_LIBGUI_FLAGS_##flag)
#define COM_ANDROID_GRAPHICS_LIBGUI_FLAGS_WB_UNLIMITED_SLOTS false
EOF
    INC+=(-Istubs)
    mkdir -p out/obj
    local srcs=(
        "$SRCDIR/HWC2.cpp"
        "$SRCDIR/HidlComposerHal.cpp"
        "$SRCDIR/AidlComposerHal.cpp"
        "$SRCDIR/ComposerHal.cpp"
        "$SRCDIR/hwc2_compatibility_layer.cpp"
        # brightness entry point upstream doesn't expose; without it SDM
        # DSPP-dims a new client's output to black (2026-07-05 finding)
        diag/hwc2_compat_extra.cpp
        aosp/hi_common/support/NativeHandle.cpp
        # HdrMetadata::operator== is the single symbol we'd otherwise import
        # from libgui.so, whose own dep chain (libpermission/PermissionCache)
        # doesn't resolve under the hybris linker. Compile it in instead.
        aosp/frameworks_native/libs/gui/HdrMetadata.cpp
    )
    local s o objs=() pids=()
    for s in "${srcs[@]}"; do
        o="out/obj/$(basename "${s%.cpp}").o"
        objs+=("$o")
        if [ ! "$o" -nt "$s" ]; then
            $CLANGXX "${CFLAGS[@]}" "${INC[@]}" -c "$s" -o "$o" & pids+=($!)
        fi
    done
    for p in "${pids[@]:-}"; do [ -n "$p" ] && wait "$p"; done
    # Link against the device's own libs; -nostdlib++ + device libc++ keeps
    # DT_NEEDED = libc++.so (the platform one), not NDK's libc++_shared.
    $CLANGXX -shared -Wl,-soname,libhwc2_compat_layer.so -Wl,--no-undefined -Wl,--allow-multiple-definition -Wl,--as-needed \
        -nostdlib++ -o out/libhwc2_compat_layer.so "${objs[@]}" \
        device-libs/*.so
    echo "OK: out/libhwc2_compat_layer.so"

    # libui_compat_layer.so -- the bionic-side gralloc shim (GraphicBuffer /
    # GraphicBufferAllocator / GraphicBufferMapper wrappers, ui_compat.cpp).
    # hybris-gralloc android_dlopen()s this; if graphic_buffer_allocator_allocate
    # is present it takes the modern A10+ allocator path (version=2), else it
    # falls back to the legacy gralloc HAL module -- which on an A16 base hands
    # out non-scanout buffers and makes SDM validateDisplay return NO_RESOURCES
    # on every frame (guest renders GLES but nothing reaches the panel). This is
    # the guest-side counterpart to libhwc2_compat_layer.so; both are required.
    $CLANGXX "${CFLAGS[@]}" "${INC[@]}" -shared -Wl,-soname,libui_compat_layer.so \
        -Wl,--no-undefined -Wl,--as-needed -nostdlib++ \
        -o out/libui_compat_layer.so \
        "$SRCDIR/../ui/ui_compatibility_layer.cpp" \
        device-libs/*.so
    echo "OK: out/libui_compat_layer.so"

    # Standalone smoke-test binary (Android-side, no libhybris involved):
    # renders GLES frames straight through the compat layer + hwcomposer.
    # Run it from adb root shell with SurfaceFlinger stopped.
    # android-config.h is libhybris-configure-generated; the version macros
    # it would carry are already on the command line.
    touch stubs/android-config.h
    # libhybris-internal logging.h; the tests only use TRACE().
    printf '#pragma once\n#define TRACE(...)\n' > stubs/logging.h
    # hybris-gralloc.c's >=10 path calls the ui compat layer through the
    # glibc-side loader (hybris_ui_*); on the Android side the functions are
    # linked in directly (ui_compatibility_layer.cpp), so the loader is a
    # no-op and every symbol probe is true.
    cat > stubs/gralloc-prelude.h <<'EOF'
#pragma once
#include <stdio.h>
#include <cutils/native_handle.h>
#include <system/window.h>
#include <android/rect.h>
#include <hybris/ui/ui_compatibility_layer.h>
extern "C" {
static inline void hybris_ui_initialize(void) {}
static inline int hybris_ui_check_for_symbol(const char *sym) { (void)sym; return 1; }
}
/* run() output must survive a timeout kill when redirected to a file */
__attribute__((constructor)) static void _hwc2_unbuf(void) { setvbuf(stdout, 0, _IONBF, 0); }
EOF
    # Keep the upstream checkout immutable. The diagnostic needs a local copy
    # with its known destructor spelling corrected.
    cp "$SRCDIR/tests/direct_hwc2_test.cpp" out/direct_hwc2_test.cpp
    sed -i 's/HWComposer2/HWComposer/g' out/direct_hwc2_test.cpp
    local TFLAGS=(-DANDROID_BUILD=1 -DHAS_GRALLOC1_HEADER=1
                  -DHWC2_USE_CPP11 -DHWC2_INCLUDE_STRINGIFICATION -I"$SRCDIR/tests")
    $CLANGXX "${CFLAGS[@]}" "${INC[@]}" "${TFLAGS[@]}" \
        -include stubs/gralloc-prelude.h -nostdlib++ \
        -o out/direct_hwc2_test \
        out/direct_hwc2_test.cpp \
        "$SRCDIR/tests/hwcomposer_window.cpp" \
        "$SRCDIR/tests/nativewindowbase.cpp" \
        "$SRCDIR/GrallocUsageConversion.cpp" \
        "$SRCDIR/../ui/ui_compatibility_layer.cpp" \
        -x c++ "$SRCDIR/tests/hybris-gralloc.c" -x none \
        out/libhwc2_compat_layer.so device-libs/*.so
    echo "OK: out/direct_hwc2_test"

    # CPU-fill diagnostic: same present path as direct_hwc2_test but the
    # buffer is solid-filled through gralloc lock (SW usage => linear, no
    # UBWC) instead of GLES. Splits "GPU never wrote the buffer" from
    # "presented buffer never reaches scanout"; see diag/.
    $CLANGXX "${CFLAGS[@]}" "${INC[@]}" "${TFLAGS[@]}" \
        -include stubs/gralloc-prelude.h -nostdlib++ \
        -Wl,--allow-multiple-definition \
        -o out/direct_hwc2_fill_test \
        diag/direct_hwc2_fill_test.cpp \
        "$SRCDIR/tests/hwcomposer_window.cpp" \
        "$SRCDIR/tests/nativewindowbase.cpp" \
        "$SRCDIR/GrallocUsageConversion.cpp" \
        "$SRCDIR/../ui/ui_compatibility_layer.cpp" \
        -x c++ "$SRCDIR/tests/hybris-gralloc.c" -x none \
        out/libhwc2_compat_layer.so device-libs/*.so
    echo "OK: out/direct_hwc2_fill_test"
    write_manifest
}

install() {
    # Into the guest rootfs (visible to the hybris linker via
    # HYBRIS_LD_LIBRARY_PATH, see guest/setup-guest.sh).
    for library in libhwc2_compat_layer.so libui_compat_layer.so; do
        [ -f "out/$library" ] || { echo "missing out/$library" >&2; exit 1; }
        "$ADB" push "out/$library" /sdcard/Download/ >/dev/null
    done
    "$ADB" shell "su -c 'set -eu; target=/data/determination/guest/usr/lib/android; \
        stage=\$target/.determination-stage-\$\$; mkdir -p \$stage; \
        for library in libhwc2_compat_layer.so libui_compat_layer.so; do \
          cp /sdcard/Download/\$library \$stage/\$library; chmod 644 \$stage/\$library; \
        done; mv \$stage/libhwc2_compat_layer.so \$target/; \
        mv \$stage/libui_compat_layer.so \$target/; rmdir \$stage'"
    echo "Installed and verified as a complete pair in guest /usr/lib/android/."
    echo "Ensure HYBRIS_LD_LIBRARY_PATH includes /usr/lib/android in the guest."
}

for stage in "${@:-fetch gen pull build}"; do "$stage"; done
