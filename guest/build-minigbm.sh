#!/bin/sh
# Build minigbm (ChromeOS's GBM implementation) as the compositor-facing GBM
# layer, into /opt/minigbm. The current device build enables its msm backend.
# Run INSIDE the container as root. Fast (small C library).
#
# WHY MINIGBM: it gives desktop compositors a compact, driver-neutral GBM API
# without selecting the GPU renderer. Compatibility rendering remains Android
# vendor EGL/GLES through libhybris. Android gralloc owns product-path buffers;
# minigbm imports compositor-facing objects from them. Direct minigbm allocation
# is retained only for the explicitly selected native-Mesa experiment until
# authoritative mapper plane metadata and fence transport are proven.
#
# WHY ITS OWN PREFIX: system libgbm (mesa's, /usr/lib) stays untouched;
# native-Mesa diagnostic sessions prepend /opt/minigbm/lib so gbm_* resolves
# to minigbm.
# If the downstream driver rejects MSM_GEM_NEW, minigbm's dumb_driver
# fallback still yields scanout-capable linear buffers — the self-test below
# prints which backend actually engaged.
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TMPDIR=/tmp
B=/root/build
PREFIX=/opt/minigbm
mkdir -p "$B"

echo "== deps (apt) =="
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git ca-certificates build-essential pkg-config libdrm-dev

echo "== clone minigbm =="
rm -rf "$B/minigbm"
git clone --depth 1 \
    https://chromium.googlesource.com/chromiumos/platform/minigbm "$B/minigbm"
cd "$B/minigbm"

# Downstream SDE registers the DRM driver as "msm_drm" (mainline: "msm");
# minigbm selects backends by drmGetVersion name, so without this the msm
# backend never engages and gbm_create_device returns NULL (verified
# 2026-07-13). Guest-only build — the mainline track wants the stock name.
sed -i 's/\.name = "msm",/.name = "msm_drm",/' msm.c
grep -q '\.name = "msm_drm",' msm.c || { echo "FATAL: msm_drm name patch did not apply"; exit 1; }

echo "== build (msm backend only) =="
# The repo Makefile is ChromeOS-flavored; a direct compile is more robust and
# transparent. Every per-SoC driver file is #ifdef DRV_* gated, so compiling
# everything with only -DDRV_MSM defined yields core + msm + dumb fallback.
rm -rf "$B/minigbm-out"; mkdir -p "$B/minigbm-out"
SRCS=$(ls ./*.c | grep -v -E "gbm_unit_test|test")
gcc -O2 -fPIC -shared -DDRV_MSM \
    $(pkg-config --cflags libdrm) \
    -Wl,-soname,libgbm.so.1 \
    -o "$B/minigbm-out/libgbm.so.1" $SRCS \
    $(pkg-config --libs libdrm) -lpthread

echo "== install to $PREFIX =="
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"
cp "$B/minigbm-out/libgbm.so.1" "$PREFIX/lib/"
ln -sf libgbm.so.1 "$PREFIX/lib/libgbm.so"
cp gbm.h minigbm_helpers.h "$PREFIX/include/" 2>/dev/null || cp gbm.h "$PREFIX/include/"

echo "== self-test: allocate / map / export on the real nodes =="
cat > "$B/minigbm-out/gbm-probe.c" <<'EOF'
/* minigbm gate: which backend engages on each node, can it allocate a
 * linear ARGB8888 BO, mmap it, and export a dmabuf fd. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <inttypes.h>
#include <gbm.h>

static int probe(const char *path, uint32_t use)
{
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("%s: open failed\n", path); return 1; }
    struct gbm_device *dev = gbm_create_device(fd);
    if (!dev) { printf("%s: gbm_create_device failed\n", path); close(fd); return 1; }
    printf("%s: backend=%s\n", path, gbm_device_get_backend_name(dev));
    struct gbm_bo *bo = gbm_bo_create(dev, 256, 256, GBM_FORMAT_ARGB8888, use);
    if (!bo) { printf("%s: gbm_bo_create(use=0x%x) FAILED\n", path, use);
               gbm_device_destroy(dev); close(fd); return 1; }
    printf("%s: bo stride=%u modifier=0x%" PRIx64 "\n", path,
           gbm_bo_get_stride(bo), (uint64_t)gbm_bo_get_modifier(bo));
    uint32_t stride = 0; void *map_data = NULL;
    void *p = gbm_bo_map(bo, 0, 0, 256, 256, GBM_BO_TRANSFER_READ_WRITE,
                         &stride, &map_data);
    if (p) { memset(p, 0xA5, stride * 256); gbm_bo_unmap(bo, map_data);
             printf("%s: map/write OK (map stride=%u)\n", path, stride); }
    else   { printf("%s: gbm_bo_map FAILED\n", path); }
    int prime = gbm_bo_get_fd(bo);
    printf("%s: dmabuf export %s (fd=%d)\n", path, prime >= 0 ? "OK" : "FAILED", prime);
    if (prime >= 0) close(prime);
    gbm_bo_destroy(bo); gbm_device_destroy(dev); close(fd);
    return p && prime >= 0 ? 0 : 1;
}

int main(void)
{
    int fail = 0;
    fail |= probe("/dev/dri/renderD128", GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
    fail |= probe("/dev/dri/card0", GBM_BO_USE_LINEAR | GBM_BO_USE_SCANOUT);
    printf(fail ? "GBM-PROBE: FAIL\n" : "GBM-PROBE: ALL PASS\n");
    return fail;
}
EOF
gcc -O2 -o "$PREFIX/bin/gbm-probe" "$B/minigbm-out/gbm-probe.c" \
    -I"$PREFIX/include" -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -lgbm
"$PREFIX/bin/gbm-probe"
echo "BUILD-MINIGBM: OK"
