#!/bin/sh
# M5 native-DRM track, Phase 0.2: build Mesa with the Turnip KGSL backend
# (Vulkan on /dev/kgsl-3d0 --- no DRM render-node submission on this downstream
# kernel) plus zink (desktop GL over Turnip). Run INSIDE the container as
# root. Expect hours on-device; that's fine (libhybris/wlroots precedent).
#
# WHY /opt/mesa AND NOT /usr/local: /usr/local/lib is the HYBRIS world ---
# libEGL.so.1 there is hybris' and desktop-on's LD_LIBRARY_PATH contract
# depends on it winning. Mesa must live in its own prefix and be selected
# per-session via /opt/mesa/env.sh. Never merge the two.
#
# WHY THESE OPTIONS:
#   - freedreno-kmds=msm,kgsl: kgsl is what this phone needs (GPU submission
#     via the downstream kgsl driver, proven on A640 by the Android
#     chroot/emulator community); msm costs nothing and keeps the build
#     reusable on the mainline track (~/op7-port).
#   - gallium-drivers=zink only: GL arrives via zink-on-Turnip. No llvm.
#   - glvnd=disabled: mesa installs its own libEGL/libGLES in /opt/mesa;
#     selection is pure LD_LIBRARY_PATH, same trick as the hybris contract.
#   - platforms=wayland (+ surfaceless, always built): no X11 in the guest.
#   - gbm=enabled: mesa's own gbm gets built but minigbm (build-minigbm.sh,
#     /opt/minigbm) is what compositors will actually get pointed at; mesa
#     gbm has no backend that can drive kgsl.
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TMPDIR=/tmp
B=/root/build
MESA_REF="${MESA_REF:-mesa-25.1.9}"
PREFIX=/opt/mesa
mkdir -p "$B"

echo "== deps (apt) =="
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git ca-certificates build-essential meson ninja-build pkg-config \
    python3-mako python3-yaml python3-packaging bison flex \
    libdrm-dev libwayland-dev libwayland-bin wayland-protocols \
    libexpat1-dev libzstd-dev zlib1g-dev libudev-dev \
    libvulkan-dev vulkan-tools libwayland-egl1

echo "== clone mesa $MESA_REF =="
rm -rf "$B/mesa"
git clone --depth 1 -b "$MESA_REF" \
    https://gitlab.freedesktop.org/mesa/mesa.git "$B/mesa"

echo "== patch: zink device selection on kgsl (phase 0.4) =="
# Turnip-KGSL exposes no VK_EXT_physical_device_drm identity, so zink's
# display-device matching can never succeed ("ZINK: failed to choose pdev")
# and GL-on-zink is dead for EGL/GBM/surfaceless. Env-gated fallback to the
# first enumerated device --- single-GPU phone, so device 0 is always right.
# Activated by ZINK_MATCH_ANY_DEVICE=1 in /opt/mesa/env.sh below.
cd "$B/mesa"
patch -p1 <<'EOF'
diff --git a/src/gallium/drivers/zink/zink_screen.c b/src/gallium/drivers/zink/zink_screen.c
--- a/src/gallium/drivers/zink/zink_screen.c
+++ b/src/gallium/drivers/zink/zink_screen.c
@@ -1654,6 +1654,16 @@ choose_pdev(struct zink_screen *screen, int64_t dev_major, int64_t dev_minor, ui
          idx = zink_get_display_device(screen, pdev_count, pdevs, dev_major,
                                        dev_minor);

+      /* Determination/kgsl: a KGSL-backed turnip device exposes no
+       * VK_EXT_physical_device_drm identity, so display-device matching can
+       * never succeed even though the driver works. On single-GPU systems,
+       * allow falling back to the first enumerated device. */
+      if (idx == -1 && !adapter_luid && !cpu &&
+          debug_get_bool_option("ZINK_MATCH_ANY_DEVICE", false)) {
+         mesa_logw("ZINK: no drm-matched device; ZINK_MATCH_ANY_DEVICE using device 0");
+         idx = 0;
+      }
+
       if (idx != -1)
          /* valid cpu device */
          screen->pdev = pdevs[idx];
EOF

echo "== configure =="
meson setup build --prefix="$PREFIX" --buildtype=release \
    -Dplatforms=wayland \
    -Dgallium-drivers=zink \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=msm,kgsl \
    -Dglx=disabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
    -Dgbm=enabled -Dglvnd=disabled -Dllvm=disabled \
    -Dbuild-tests=false

echo "== build (this is the hours part) =="
ninja -C build -j"$(nproc)"

echo "== install to $PREFIX =="
rm -rf "$PREFIX"
ninja -C build install

echo "== session env contract =="
LIBDIR="$PREFIX/lib/aarch64-linux-gnu"
ICD="$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
cat > "$PREFIX/env.sh" <<EOF
# Mesa/native session env (M5 native-DRM track). Mutually exclusive with the
# hybris env in /etc/profile.d/hybris.sh --- do NOT put /usr/local/lib here.
export LD_LIBRARY_PATH=$LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export VK_DRIVER_FILES=$ICD
export LIBGL_DRIVERS_PATH=$LIBDIR/dri
export MESA_LOADER_DRIVER_OVERRIDE=zink
# kgsl turnip has no VK_EXT_physical_device_drm --- see the zink patch in
# build-mesa.sh; without this GL-on-zink cannot find the GPU.
export ZINK_MATCH_ANY_DEVICE=1
EOF
chmod 644 "$PREFIX/env.sh"

echo "== gate: Turnip enumerates over kgsl =="
# vulkaninfo works headless. deviceName should read "Turnip Adreno (TM) 640".
if VK_DRIVER_FILES="$ICD" LD_LIBRARY_PATH="$LIBDIR" vulkaninfo --summary \
        2>/tmp/vulkaninfo.err | tee /tmp/vulkaninfo.out | grep -i turnip; then
    echo "BUILD-MESA: OK (Turnip live --- see /tmp/vulkaninfo.out)"
else
    echo "BUILD-MESA: INSTALLED BUT TURNIP NOT ENUMERATING"
    echo "-- vulkaninfo stderr:"; tail -20 /tmp/vulkaninfo.err
    echo "   (kgsl UAPI mismatch is the known risk --- this is the kill-switch)"
    exit 1
fi
