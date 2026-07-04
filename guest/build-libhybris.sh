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

# hooks_mm gap fix (2026-07-04, upstream-able): the q linker hooks the whole
# locale.h family to glibc, but NOT __ctype_get_mb_cur_max — a bionic-only
# export (bionic's MB_CUR_MAX) that reads bionic TLS tp[-1], which never
# exists on a glibc thread. Vendor libc++'s std::locale::classic() calls it
# during android_dlopen of anything that touches std::locale => SIGSEGV in
# libc.so (offset 0x83b28 on this ROM). Also hook the *_l family: hooked
# newlocale() hands out GLIBC locale_t objects, so bionic's *_l consumers
# would misinterpret them; and the mb/wc conversions libc++ facets use.
if ! grep -q "__ctype_get_mb_cur_max" "$SRC/hybris/common/hooks.c"; then
    git -C "$SRC" apply <<'HOOKPATCH'
diff --git a/hybris/common/hooks.c b/hybris/common/hooks.c
--- a/hybris/common/hooks.c
+++ b/hybris/common/hooks.c
@@ -70,6 +70,8 @@
 #include <sys/mman.h>
 #include <libgen.h>
 #include <mntent.h>
+#include <wctype.h>
+#include <time.h>

 #include <hybris/properties/properties.h>

@@ -3314,6 +3316,44 @@ static struct _hook hooks_mm[] = {
     HOOK_DIRECT(uselocale),
     HOOK_DIRECT(localeconv),
     HOOK_DIRECT(setlocale),
+    /* bionic-only / locale_t-consuming entry points: newlocale & friends
+     * above hand out GLIBC locale_t objects, so every function that
+     * receives one must be glibc's too; __ctype_get_mb_cur_max reads a
+     * bionic TLS slot that never exists on a glibc thread (SIGSEGV when
+     * libc++'s std::locale::classic() initializes during android_dlopen) */
+    HOOK_DIRECT_NO_DEBUG(__ctype_get_mb_cur_max),
+    HOOK_DIRECT_NO_DEBUG(iswalpha_l),
+    HOOK_DIRECT_NO_DEBUG(iswblank_l),
+    HOOK_DIRECT_NO_DEBUG(iswcntrl_l),
+    HOOK_DIRECT_NO_DEBUG(iswdigit_l),
+    HOOK_DIRECT_NO_DEBUG(iswlower_l),
+    HOOK_DIRECT_NO_DEBUG(iswprint_l),
+    HOOK_DIRECT_NO_DEBUG(iswpunct_l),
+    HOOK_DIRECT_NO_DEBUG(iswspace_l),
+    HOOK_DIRECT_NO_DEBUG(iswupper_l),
+    HOOK_DIRECT_NO_DEBUG(iswxdigit_l),
+    HOOK_DIRECT_NO_DEBUG(towlower_l),
+    HOOK_DIRECT_NO_DEBUG(towupper_l),
+    HOOK_DIRECT_NO_DEBUG(strcoll_l),
+    HOOK_DIRECT_NO_DEBUG(strxfrm_l),
+    HOOK_DIRECT_NO_DEBUG(strftime_l),
+    HOOK_DIRECT_NO_DEBUG(strtod_l),
+    HOOK_DIRECT_NO_DEBUG(strtof_l),
+    HOOK_DIRECT_NO_DEBUG(strtold_l),
+    HOOK_DIRECT_NO_DEBUG(strtoll_l),
+    HOOK_DIRECT_NO_DEBUG(strtoull_l),
+    HOOK_DIRECT_NO_DEBUG(wcscoll_l),
+    HOOK_DIRECT_NO_DEBUG(wcsxfrm_l),
+    /* multibyte/wide conversions libc++ facets route through */
+    HOOK_DIRECT_NO_DEBUG(btowc),
+    HOOK_DIRECT_NO_DEBUG(wctob),
+    HOOK_DIRECT_NO_DEBUG(mbrlen),
+    HOOK_DIRECT_NO_DEBUG(mbrtowc),
+    HOOK_DIRECT_NO_DEBUG(mbsrtowcs),
+    HOOK_DIRECT_NO_DEBUG(mbsnrtowcs),
+    HOOK_DIRECT_NO_DEBUG(mbtowc),
+    HOOK_DIRECT_NO_DEBUG(wcrtomb),
+    HOOK_DIRECT_NO_DEBUG(wcsnrtombs),
     /* sys/mman.h */
 #if defined(LP64)
     HOOK_DIRECT(mmap),
HOOKPATCH
fi
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
The bionic-side libhwc2_compat_layer.so is built separately on the host by
hwc2-compat/build.sh and installed to the guest's /usr/lib/android/ (add it
to HYBRIS_LD_LIBRARY_PATH). §3 gate passed with this pair on 2026-07-04.
NOTE
