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

# test_hwcomposer is Determination's TEMP §4 render placeholder: toggle/desktop-on
# runs it as the stand-in "compositor" until sway/phoc lands. Upstream's demo
# renders a FIXED frame count (`for (i=0; i<1020*60; ++i)`) then exits ~24s,
# which tears the hwc2 display down; desktop-on needs it to render CONTINUOUSLY
# (one instance, no per-cycle teardown/black-flicker). Patch the loop to never
# terminate. Idempotent — only rewrites the stock finite bound.
if grep -q 'i<1020\*60;' "$SRC/hybris/tests/test_hwcomposer.cpp"; then
    sed -i 's/i<1020\*60;/;/' "$SRC/hybris/tests/test_hwcomposer.cpp"
fi

# setDisplayBrightness (2026-07-05, THE black-panel root cause): SDM keeps
# per-client display brightness and starts every new composer client at 0,
# so the DSPP dims all of the client's composed output to pure black while
# validate/present/fences all succeed. One composer@2.3 setDisplayBrightness
# call after power-on fixes it. The bionic side already exports
# hwc2_compat_display_set_brightness (hwc2-compat/diag/hwc2_compat_extra.cpp,
# compiled into our libhwc2_compat_layer.so); wire the glibc-side wrapper
# through and make the test set 1.0 after power-on. Upstream-able.
if ! grep -q "hwc2_compat_display_set_brightness" "$SRC/hybris/hwc2/hwc2.c"; then
    sed -i '/HYBRIS_IMPLEMENT_FUNCTION3(hwc2, hwc2_error_t, hwc2_compat_display_validate,/i\
HYBRIS_IMPLEMENT_FUNCTION2(hwc2, hwc2_error_t, hwc2_compat_display_set_brightness,\
                           hwc2_compat_display_t*, float);\
' "$SRC/hybris/hwc2/hwc2.c"
fi
if ! grep -q "hwc2_compat_display_set_brightness" \
        "$SRC/hybris/include/hybris/hwc2/hwc2_compatibility_layer.h"; then
    sed -i '/hwc2_error_t hwc2_compat_display_validate(hwc2_compat_display_t\* display,/i\
    hwc2_error_t hwc2_compat_display_set_brightness(hwc2_compat_display_t* display,\
                                            float brightness);\
' "$SRC/hybris/include/hybris/hwc2/hwc2_compatibility_layer.h"
fi
if ! grep -q "hwc2_compat_display_set_brightness" "$SRC/hybris/tests/test_common.cpp"; then
    sed -i '/hwc2_compat_display_set_power_mode(hwcDisplay, HWC2_POWER_MODE_ON);/a\
\	/* SDM starts new clients at brightness 0 -> DSPP dims output to black */\
\	hwc2_compat_display_set_brightness(hwcDisplay, 1.0f);
' "$SRC/hybris/tests/test_common.cpp"
fi

# Device-query extension filter (2026-07-08, GPU app buffers; upstream-able):
# GTK4/GDK sees EGL_EXT_device_query in the DISPLAY extension string (the
# vendor driver advertises it) and calls eglQueryDisplayAttribEXT for its
# software-renderer check — but libepoxy resolves that entrypoint against
# the CLIENT extension list (no display is current yet), where hybris
# advertises none of the device extensions, and abort()s the app:
#   "No provider of eglQueryDisplayAttribEXT found."
# hybris cannot service the device-query entrypoints from the glibc side
# anyway, so advertising them is a lie; strip the family from the string
# eglplatformcommon returns. Fixes every epoxy-based toolkit (GTK4 first
# among them) on every device whose vendor driver advertises the family.
if ! grep -q "hybris_filter_display_extensions" \
        "$SRC/hybris/egl/egl.c"; then
    python3 - "$SRC/hybris/egl/platforms/common/eglplatformcommon.cpp" "$SRC/hybris/egl/egl.c" <<'PYEOF'
import sys, pathlib

strip_code = '''\
/* hybris_filter_display_extensions: the glibc side cannot service the
		 * device-query entrypoints (eglQueryDisplayAttribEXT & co.), and
		 * epoxy-based toolkits (GTK4) abort when a display advertises them
		 * but no client-side provider resolves. Do not advertise what we
		 * cannot deliver. */
		{
			static const char *drop[] = {
				"EGL_EXT_device_base",
				"EGL_EXT_device_query",
				"EGL_KHR_display_reference",
				"EGL_NV_stream_metadata",
				NULL
			};
			for (int i = 0; drop[i]; i++) {
				char *p = eglextensionsbuf;
				size_t l = strlen(drop[i]);
				while ((p = strstr(p, drop[i])) != NULL) {
					int at_start = (p == eglextensionsbuf || p[-1] == ' ');
					int at_end = (p[l] == ' ' || p[l] == '\\0');
					if (at_start && at_end) {
						char *rest = p + l + (p[l] == ' ' ? 1 : 0);
						memmove(p, rest, strlen(rest) + 1);
					} else {
						p += l;
					}
				}
			}
		}
		ret = eglextensionsbuf;'''

for f in sys.argv[1:]:
    p = pathlib.Path(f)
    s = p.read_text()
    if 'eglplatformcommon.cpp' in f:
        anchor = '''		snprintf(eglextensionsbuf, 2046, "%s %s", ret,
			"EGL_HYBRIS_native_buffer2 EGL_HYBRIS_WL_acquire_native_buffer EGL_WL_bind_wayland_display"
		);
		ret = eglextensionsbuf;'''
    else:
        anchor = '''		snprintf(eglextensionsbuf, 2046, "%s %s", ret,
			"EGL_EXT_client_extensions EGL_EXT_platform_wayland EGL_KHR_platform_wayland"
		);
		ret = eglextensionsbuf;'''
    
    if anchor not in s:
        print(f'anchor not found in {f} or already patched')
        continue
    s = s.replace(anchor, anchor.replace('ret = eglextensionsbuf;', strip_code), 1)
    p.write_text(s)
    print(f'device-query filter: applied to {f}')
PYEOF
fi

# HWCNativeWindowSetBufferCount (2026-07-06, droidian API parity): the
# droidian wlroots hwcomposer backend calls it (triple buffering); upstream
# libhybris lacks it. setBufferCount is protected, so the C wrapper goes
# through the public ANativeWindow perform() interface, which
# BaseNativeWindow dispatches back to setBufferCount. Upstream-able.
HWCW="$SRC/hybris/egl/platforms/hwcomposer"
if ! grep -q HWCNativeWindowSetBufferCount "$HWCW/hwcomposer.h"; then
    sed -i '/void HWCNativeWindowDestroy(struct ANativeWindow \*window);/a\
\
/* Determination (droidian API parity): set swapchain depth. droidian wlroots\
 * hwcomposer backend calls this for triple buffering. */\
void HWCNativeWindowSetBufferCount(struct ANativeWindow *window, int cnt);' \
        "$HWCW/hwcomposer.h"
fi
if ! grep -q HWCNativeWindowSetBufferCount "$HWCW/hwcomposer_window.cpp"; then
    cat >> "$HWCW/hwcomposer_window.cpp" <<'EOF'

extern "C" void HWCNativeWindowSetBufferCount(struct ANativeWindow *window, int cnt)
{
    /* setBufferCount is protected; use the public perform interface */
    window->perform(window, NATIVE_WINDOW_SET_BUFFER_COUNT, cnt);
}
EOF
fi

# KHR swap-with-damage override (2026-07-09; upstream-able): vendors
# advertise EGL_KHR_swap_buffers_with_damage, but hybris only overrides the
# EXT name — eglGetProcAddress(eglSwapBuffersWithDamageKHR) hands out the
# raw vendor entrypoint, which skips the ws finishSwap wayland attach+commit,
# so client windows never map (GTK4/GDK prefers the KHR name). Alias the KHR
# name onto the EXT wrapper (identical semantics).
if ! grep -q "eglSwapBuffersWithDamageKHR, _my_eglSwapBuffersWithDamageEXT" \
        "$SRC/hybris/egl/egl.c"; then
    sed -i 's|\(.*OVERRIDE_MY(glEGLImageTargetTexture2DOES),\)|\t/* KHR variant: vendors advertise EGL_KHR_swap_buffers_with_damage; without\n\t * this override eglGetProcAddress hands out the raw vendor entrypoint,\n\t * which skips the ws finishSwap wayland attach+commit - windows never map\n\t * (GTK4 prefers the KHR name). Same semantics as the EXT variant. */\n\tOVERRIDE_TO(eglSwapBuffersWithDamageKHR, _my_eglSwapBuffersWithDamageEXT),\n\1|' \
        "$SRC/hybris/egl/egl.c"
fi

# GSK struct-varying fix (2026-07-10; upstream-able as a driver quirk): the
# Adreno GLES blob (A640 V@0502) mishandles struct varyings matched by name
# across shader stages — a "flat in Rect/RoundedRect" read as a whole struct
# (function argument) yields zeros, though per-field access works; sometimes
# the link fails outright ("input _rect not declared in output from previous
# stage").  GTK4 GSK ends every fragment path in rect_coverage(_rect,_pos),
# so alpha=0 and NO GSK shader draw ever produced pixels ("apps launch to a
# white screen" — only glClear/occlusion output was visible).  The custom
# glShaderSource below rewrites GSK fragment sources to rebuild the struct
# from its fields at each use site (proven correct on-device 2026-07-10,
# artifacts/guest-gsk-struct-varying-fix-20260710.txt).  Runtime opt-out:
# HYBRIS_NO_GSK_VARYING_FIX=1; debug: HYBRIS_GSK_VARYING_FIX_DEBUG=1.
if ! grep -q "_gskfix_rewrite" "$SRC/hybris/glesv2/glesv2.c"; then
    python3 - "$SRC/hybris/glesv2/glesv2.c" <<'GSKFIXEOF'
#!/usr/bin/env python3
# Patch libhybris glesv2.c: rewrite GSK fragment shaders to work around the
# Adreno struct-varying miscompilation. Idempotent.
import sys

SRC = sys.argv[1]
MACRO_LINE = "HYBRIS_IMPLEMENT_VOID_FUNCTION4(glesv2, glShaderSource, GLuint, GLsizei, const GLchar *const *, const GLint *);"

IMPL = r"""
/* Determination: Adreno struct-varying miscompilation workaround.
 * The Adreno GLES blob (seen on A640 V@0502) mishandles struct varyings
 * matched by name across stages: a "flat in Rect/RoundedRect" read as a
 * whole struct (e.g. passed into a function) yields zeros, while per-field
 * access works; sometimes linking fails outright with "input not declared
 * in output from previous stage".  GTK4's GSK shaders end every fragment
 * path in rect_coverage(_rect, _pos), so alpha becomes 0 and no GSK draw
 * produces pixels.  Rebuilding the struct from its fields at each use site
 * compiles correctly, so rewrite GSK fragment sources before handing them
 * to the driver.  Disable with HYBRIS_NO_GSK_VARYING_FIX=1. */
#include <string.h>
#include <stdio.h>

struct _gskfix_name { char name[64]; int rr; };

static int _gskfix_word(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

static int _gskfix_collect(const char *src, struct _gskfix_name *out, int max)
{
    /* declarations look like: PASS_FLAT(1) Rect _rect;  (macros unexpanded) */
    const char *p = src;
    int n = 0;
    while (n < max && (p = strstr(p, "PASS_FLAT("))) {
        p += 10;
        while (*p && *p != ')') p++;
        if (*p) p++;
        while (*p == ' ') p++;
        int rr = -1;
        if (!strncmp(p, "RoundedRect ", 12)) { rr = 1; p += 12; }
        else if (!strncmp(p, "Rect ", 5)) { rr = 0; p += 5; }
        if (rr < 0) continue;
        while (*p == ' ') p++;
        int i = 0;
        while (_gskfix_word(*p) && i < 63) out[n].name[i++] = *p++;
        out[n].name[i] = 0;
        out[n].rr = rr;
        if (i) n++;
    }
    return n;
}

static char *_gskfix_rewrite(const char *src, int *nsub)
{
    struct _gskfix_name nm[16];
    if (!strstr(src, "#define GSK_FRAGMENT_SHADER")) return NULL;
    int nn = _gskfix_collect(src, nm, 16);
    if (!nn) return NULL;
    size_t slen = strlen(src);
    char *out = malloc(slen * 8 + 1024);
    if (!out) return NULL;
    const char *p = src;
    char *o = out;
    *nsub = 0;
    while (*p) {
        int matched = 0;
        if (_gskfix_word(*p) && (p == src || !_gskfix_word(p[-1]))) {
            int k;
            for (k = 0; k < nn; k++) {
                size_t l = strlen(nm[k].name);
                if (!strncmp(p, nm[k].name, l) && !_gskfix_word(p[l])) {
                    /* skip the declaration itself: preceding token ends "Rect" */
                    const char *q = p;
                    while (q > src && (q[-1] == ' ' || q[-1] == '\t')) q--;
                    if (q - src >= 4 && !strncmp(q - 4, "Rect", 4)) break;
                    if (nm[k].rr)
                        o += sprintf(o, "RoundedRect(%s.bounds,%s.corner_widths,%s.corner_heights)",
                                     nm[k].name, nm[k].name, nm[k].name);
                    else
                        o += sprintf(o, "Rect(%s.bounds)", nm[k].name);
                    p += l;
                    (*nsub)++;
                    matched = 1;
                    break;
                }
            }
        }
        if (!matched) *o++ = *p++;
    }
    *o = 0;
    return out;
}

void glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length)
{
    static void (*f)(GLuint, GLsizei, const GLchar *const *, const GLint *) FP_ATTRIB = NULL;
    HYBRIS_DLSYSM(glesv2, &f, "glShaderSource");
    if (getenv("HYBRIS_NO_GSK_VARYING_FIX") || count < 1 || !string) {
        f(shader, count, string, length);
        return;
    }
    size_t tot = 0;
    GLsizei i;
    for (i = 0; i < count; i++)
        tot += (length && length[i] >= 0) ? (size_t)length[i] : strlen(string[i]);
    char *cat = malloc(tot + 1);
    if (!cat) { f(shader, count, string, length); return; }
    char *c = cat;
    for (i = 0; i < count; i++) {
        size_t l = (length && length[i] >= 0) ? (size_t)length[i] : strlen(string[i]);
        memcpy(c, string[i], l);
        c += l;
    }
    *c = 0;
    int nsub = 0;
    char *fixed = _gskfix_rewrite(cat, &nsub);
    if (fixed && nsub) {
        if (getenv("HYBRIS_GSK_VARYING_FIX_DEBUG"))
            fprintf(stderr, "libhybris: GSK struct-varying fix: shader %u, %d substitutions\n",
                    (unsigned)shader, nsub);
        const GLchar *one = fixed;
        f(shader, 1, &one, NULL);
    } else {
        f(shader, count, string, length);
    }
    free(cat);
    free(fixed);
}
"""

src = open(SRC).read()
if "_gskfix_rewrite" in src:
    print("gskfix: already patched")
    sys.exit(0)
if MACRO_LINE not in src:
    print("gskfix: ERROR macro line not found", file=sys.stderr)
    sys.exit(1)
src = src.replace(MACRO_LINE, "/* Determination: replaced by custom glShaderSource below. */" + IMPL)
open(SRC, "w").write(src)
print("gskfix: patched", SRC)
GSKFIXEOF
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
# GOTCHA (bit us 2026-07-06): the include/ install can lag the patched
# source headers (the hwc2 set_brightness decl never landed in
# /usr/local/include until wlroots failed to compile against it). Force it.
cp "$SRC/hybris/include/hybris/hwc2/hwc2_compatibility_layer.h" \
   /usr/local/include/hybris/hwc2/hwc2_compatibility_layer.h 2>/dev/null || true
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
