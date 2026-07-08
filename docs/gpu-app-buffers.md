# GPU-accelerated app buffers (zero-copy client rendering)

How Wayland clients in the Determination guest render on the device GPU and
hand their frames to phoc without a copy — and why this design is portable
to essentially any Halium-capable Android device, not just the OnePlus 7.

## The problem

The compositor (phoc, on the droidian wlroots hwcomposer backend) has been
GPU-accelerated since §3. Clients were not: with no usable client EGL they
fell back to `wl_shm` — software rasterization (GTK's cairo path) plus a
full-frame copy and a texture upload every frame. Fine for a terminal,
hopeless for real apps.

The standard Linux answer — Mesa + `linux-dmabuf` — is **not available** on
libhybris systems: the vendor EGL driver sits behind bionic, buffers are
gralloc handles rather than dmabufs you can import with
`EGL_EXT_image_dma_buf_import`, and downstream kernels (this one: msm 4.14
with kgsl) have no DRM render node for Mesa to drive. Any dmabuf-based
design would be a per-device science project. The portable currency of an
Android device is the **gralloc buffer**, and the portable GPU entry point
is the **vendor EGL via libhybris**.

## The architecture (all pieces already shipped; this work wires them)

```
app (GTK4 / Qt / SDL / glmark2 …)
  └─ libEGL.so.1 = HYBRIS EGL       (/usr/local/lib wins over glvnd/Mesa)
       EGL_PLATFORM=wayland → eglplatform_wayland.so (hybris "ws")
       └─ vendor EGL/GLES driver (bionic side, via the hybris linker)
            renders into a gralloc-backed ANativeWindowBuffer
       └─ android_wlegl protocol: passes the gralloc handle (fds+ints)
          to the compositor as a wl_buffer            [zero-copy]
phoc / wlroots (android renderer, hybris EGL on the hwcomposer platform)
  └─ wlr_android_wlegl (server side, in the droidian wlroots fork):
       reconstructs the ANativeWindowBuffer (hybris_gralloc_import_buffer)
  └─ eglCreateImageKHR(EGL_WAYLAND_BUFFER_WL) → EGLImage
       sampled as GL_TEXTURE_EXTERNAL_OES              [zero-copy]
  └─ composited scene → hwcomposer2 → panel
```

Both halves speak `android_wlegl` (protocol XML lives in both trees). No
Determination-specific patch is needed for the buffer path itself — the
work is environment wiring plus verification.

### Who provides what

| Piece | Source | Requirement |
|---|---|---|
| Client EGL + wayland platform | upstream `libhybris/libhybris` master | build with `--enable-wayland` (see `guest/build-libhybris.sh`); installs `libhybris/eglplatform_wayland.so` + `libEGL.so.1`/`libGLESv2.so.2` |
| `android_wlegl` server + import | droidian wlroots fork, `-Drenderers=gles2,android` | `types/android_wlegl/wlr_android_wlegl.c`, `render/android/renderer.c` (see `guest/build-wlroots-phoc.sh`) |
| Buffer allocation | gralloc via libhybris (both sides) | any gralloc 3/4 device |
| EGLImage import | vendor EGL `EGL_ANDROID_image_native_buffer` | universally present on Android vendor drivers |

## The environment contract (the part that was missing)

One process tree, two EGL personalities:

- **Compositor** (`toggle/desktop-on` step 5, `guest/*-smoke.sh`):
  `EGL_PLATFORM=hwcomposer` — owns the panel through hwc2.
- **Clients** (`toggle/desktop-on` step 5e session, `/etc/profile.d/hybris.sh`):
  `EGL_PLATFORM=wayland` + the same `HYBRIS_LD_LIBRARY_PATH` as the
  compositor + `/usr/local/lib` first in `LD_LIBRARY_PATH`.

Three traps, all load-bearing:

1. **`EGL_PLATFORM` default.** Hybris maps
   `eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR)` to the wayland
   platform explicitly (GTK4/epoxy take this path), but any client calling
   plain `eglGetDisplay()` gets the *configure-time default* —
   `hwcomposer` in our build — and will fight the compositor for the
   composer HAL. Clients must run with `EGL_PLATFORM=wayland`.
2. **`HYBRIS_LD_LIBRARY_PATH` in clients.** The vendor EGL and apex bionic
   libc must resolve inside every *client* process, not just phoc. Without
   it hybris EGL fails to load the driver and toolkits silently fall back
   to software.
3. **Library ordering.** glvnd/Mesa's `libEGL.so.1` in
   `/lib/aarch64-linux-gnu` must lose to hybris' in `/usr/local/lib`
   (session `LD_LIBRARY_PATH`; same rule as the stale-z4-debs problem).

Also set for GTK4: `GSK_RENDERER=ngl` (skip the Vulkan probe — no hybris
Vulkan platform installed; the GLES "ngl" renderer is the accelerated
target).

## Portability notes (the "tons of devices" contract)

- Nothing above references this device. Formats and usage bits are
  negotiated per-buffer through gralloc; the GPU is whatever the vendor
  driver says (`Adreno`, `Mali`, `PowerVR` — the smoke test accepts any).
- Works on HIDL (composer 2.1–2.4) and AIDL devices alike: the client
  buffer path never touches the composer HAL, only gralloc + EGL.
- The one ABI subtlety: wlroots' `wlr_android_wlegl_buffer_remote_buffer`
  hand-mimics the layout of hybris' C++ `RemoteWindowBuffer` (8-byte
  header standing in for the vptr, `ANativeWindowBuffer` at offset 8), so
  hybris' `eglCreateImageKHR(EGL_WAYLAND_BUFFER_WL)` can cast the resource
  straight into it. That layout is unchanged in hybris since 2012, but if
  upstream ever adds a field, phoc crashes on the first client buffer —
  re-check `hybris/platforms/common/server_wlegl_buffer.h` against
  `include/wlr/types/wlr_android_wlegl.h` after any libhybris bump.
- Hard failure mode to know: hybris' wayland platform **`abort()`s the
  client** if the compositor doesn't advertise `android_wlegl` (e.g.
  running an app against a stock wlroots/GNOME compositor with
  `EGL_PLATFORM=wayland` forced). A graceful `EGL_NO_DISPLAY` fallback
  would be a good upstream patch.
- Explicit sync is absent (no dmabuf fences over the protocol); the
  droidian ecosystem ships this way. Watch for glitch reports; the fix
  lane upstream is the wlegl v3 / fence-fd discussions, not ours.

## Verification

`guest/gpu-smoke.sh` (run as root on the phone):

1. `gpu-smoke.sh prep` in **phone mode** — installs `glmark2-es2-wayland`
   + `wayland-utils` into the guest (network is only reliable in phone
   mode).
2. `gpu-smoke.sh` in **desktop mode** (announce first — windows appear on
   the panel): checks the platform plugin, the `android_wlegl` global,
   runs glmark2 (vendor `GL_RENDERER` string + FPS = proof the buffer path
   is GPU end-to-end), then a GTK4 app under `GDK_DEBUG=opengl` and
   confirms it mapped *hybris'* libEGL.

Evidence convention: tee output to `artifacts/guest-gpu-smoke-<date>.txt`.

## Status

- 2026-07-08: designed + wired host-side (desktop-on 5e env, profile.d
  default, build prereq check, smoke script). **Not yet run on device** —
  awaiting go-ahead. Expected first-run risks: GTK4/epoxy entrypoint
  quirks (hybris does export `eglCreatePlatformWindowSurface` and
  advertises `EGL_EXT_platform_wayland`, so none anticipated), buffer
  format mismatches (RGBA vs RGBX), fence-less glitches under load.

## Upstream candidates from this work

- libhybris: graceful failure instead of `abort()` when `android_wlegl`
  is missing.
- libhybris: the already-flagged patches in `guest/build-libhybris.sh`
  (hooks_mm locale family, `hwc2_compat_display_set_brightness`,
  `HWCNativeWindowSetBufferCount`).
- droidian wlroots: the EVIOCGRAB handoff and DSPP-brightness patches in
  `guest/build-wlroots-phoc.sh`.
