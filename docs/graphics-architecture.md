# Compatibility graphics architecture

Determination's product graphics invariant is:

> Use the device's Android vendor EGL/GLES implementation through libhybris.

Turnip/KGSL proved that native Mesa can work on `guacamoleb`; it is not the
portable renderer. Minigbm is not a renderer either. Its intended role is to
provide the standard GBM-facing buffer API expected by desktop compositors
while Android gralloc remains the source of allocations and vendor-private
layout metadata.

## Layers, kept deliberately separate

| Layer | Compatibility implementation | Optional optimisation |
|---|---|---|
| GPU rendering | vendor EGL/GLES through libhybris | native Mesa when explicitly selected for diagnostics |
| allocation | Android gralloc through libhybris | device-proven minigbm allocation |
| compositor GBM API | minigbm importing Android-owned buffers | direct minigbm allocation after a round-trip gate |
| display | libhybris/hwcomposer or Android presenter | native KMS when Android is suspended |

This is not achieved by placing both libraries in `LD_LIBRARY_PATH`. KWin 6's
DRM and nested-Wayland OpenGL backends allocate dma-bufs through GBM and create
EGLImages from dma-buf plane metadata. Android vendor EGL normally consumes an
`ANativeWindowBuffer` carrying a complete gralloc `native_handle` instead.
Bridging those object models is the work.

## Buffer ownership

Compatibility mode is Android-owned:

```text
libhybris → Android gralloc allocation
          → full native_handle (fds + private ints)
          → vendor EGLImage / GLES rendering
          → minigbm import for the compositor-facing GBM object
          → HWC or Android presenter
```

The complete native handle must remain attached to every buffer. A dma-buf fd
alone is not an Android buffer contract: additional fds may contain compression
metadata, and private integers encode vendor mapper information.

The reverse direction:minigbm allocation imported into Android:is an optional
fast path. It is enabled only when allocation, vendor EGL import, mapper import,
presentation and synchronization all pass on the device. Matching a FourCC and
stride is not enough.

## Gate 1: one shared allocation

`guest/hybris-minigbm-probe.c` is the first executable gate. It uses no Mesa or
Vulkan code. It:

1. initializes libhybris with the display-less `null` platform;
2. allocates RGBA8888 through Android gralloc;
3. serializes the complete gralloc native handle;
4. reconstructs a second gralloc object from that full handle;
5. creates a vendor EGLImage for the reconstructed object, renders through it
   with vendor GLES, and verifies pixels through the original allocation;
6. selects the probable pixel dma-buf for this diagnostic only;
7. imports and re-exports it through minigbm;
8. exports a vendor EGL native fence, waits its sync-file, and re-imports it;
9. wraps the complete native handle as an `AHardwareBuffer`, transports it
   over an AF_UNIX socket using Android's native API, and verifies its metadata
   at the receiver.

Build inside the guest:

```sh
sh /root/build-hybris-minigbm-probe.sh /root/hybris-minigbm-probe.c
```

The probe is safe in phone mode: the null EGL platform initializes vendor EGL
and gralloc without acquiring hwcomposer. A pass now establishes shared
allocation, explicit producer-fence transport, and Android's complete-handle
IPC primitive. Authoritative multi-plane metadata, compositor integration,
HWC/presenter submission and recovery each retain their own gate.

### Result on guacamoleb

**PASS, 2026-07-19.** The QTI gralloc allocation carried two fds and 22 private
integers. The full handle was serialized and reconstructed through libhybris;
vendor Adreno EGL rendered RGBA `64,128,191,255` through that reconstructed
object and CPU gralloc readback through the original allocation returned the
same value. Minigbm's `msm_drm` backend then imported and re-exported the 256 KiB
pixel dma-buf. The second 32 KiB fd is further evidence that a one-fd GBM
abstraction is not the complete Android buffer contract. Vendor EGL also
exported a signalling native fence which survived sync-file polling and EGL
re-import. Finally the complete handle was cloned into an `AHardwareBuffer`,
sent through Android's Unix-socket transport, received, and described as the
same 256x256 RGBA8888 allocation.

Captured outputs: `artifacts/hybris-minigbm-20260719.txt` and
`artifacts/hybris-minigbm-fence-ahb-20260719.txt`.

## Performance gate

Run the display-safe benchmark with:

```sh
./det hybrid-bench
# Optional reproducible geometry/count override:
./det hybrid-bench 1080 2340 240
```

On guacamoleb at 1080x2340, 30 warmup + 240 measured frames produced:

| Operation | Mean | p95 | p99 |
|---|---:|---:|---:|
| vendor EGL clear + `glFinish` | 0.920 ms | 1.115 ms | 1.180 ms |
| four fullscreen textured/blended layers + `glFinish` | 4.263 ms | 4.468 ms | 4.625 ms |
| full native-handle import/release | 8 us | 8 us | 9 us |
| minigbm import/export | 92 us | 116 us | 161 us |

The four-layer result repeated within 0.5% for mean frame time across three
full-resolution runs. It fits comfortably inside a 16.67 ms 60 Hz budget and
inside an 8.33 ms 120 Hz budget for this synthetic workload. That is GPU-path
headroom, not an end-to-end desktop claim: KWin scheduling, presentation,
explicit fences, display vsync and the Android presenter are not implemented in
this benchmark. Handle and minigbm imports are buffer-pool setup costs and
should not occur every frame.

Raw results: `artifacts/hybris-minigbm-benchmark-20260719.txt`.

## Remaining direct-KWin work

The direct path needs an Android-backed GBM/EGL winsys rather than a Turnip
session launcher:

1. preserve a libhybris `EGLClientBuffer` and its full native handle beside
   every compositor-visible GBM BO;
2. expose authoritative plane fd, offset, stride and modifier metadata through
   mapper-version adapters;
3. create vendor EGLImages with `EGL_NATIVE_BUFFER_HYBRIS`, not dma-buf import;
4. carry the now-proven acquire and release `sync_file` primitive through every
   ownership transfer;
5. implement linear/copy fallback when native zero-copy import is unavailable;
6. integrate the winsys with KWin without teaching KWin about any GPU vendor.

Until those gates pass, the proven compatibility desktop remains phoc/wlroots
on libhybris/HWC with application buffers transported through `android_wlegl`.
The native Turnip/KMS Plasma result remains valuable evidence, but it is an
explicit experiment and cannot be selected accidentally by the default config.
