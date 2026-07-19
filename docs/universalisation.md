# Project Universalisation

Determination currently has one proven device: OnePlus 7 `guacamoleb`. The
portable architecture is a hypothesis until a second device crosses a
meaningfully different hardware or Android axis. This document tracks the work
needed to make that hypothesis testable.

## Configuration contract

Host-side scripts source `/data/determination/bin/device-config`. It discovers
safe defaults at runtime and then applies the data-only overrides in
`/data/determination/etc/device.conf`.

Currently configurable end to end:

| Key | Discovery/default | Consumers |
|---|---|---|
| `DET_BACKLIGHT_PATH` | known Android paths, then first backlight node | HWC and native toggle paths |
| `DET_BACKLIGHT_LEVEL` | one third of `max_brightness` | HWC and native toggle paths |
| `DET_WIFI_IFACE` | first `wlan*` or `wifi*` interface | guest network keeper/routing |
| `DET_HWC_OUTPUT` | `HWCOMPOSER-1` | generated phoc configuration |
| `DET_PANEL_WIDTH`, `DET_PANEL_HEIGHT` | Android physical display size | scale calculation and diagnostics |
| `DET_OUTPUT_SCALE` | approximately 360 logical pixels wide | generated phoc configuration |
| `DET_BATTERY_GAUGE` | unset | guest battery translator |
| `DET_INPUT_QUIRK` | `none` | classified libinput workaround |
| `DET_DRM_CARD` | `/dev/dri/card0` | reserved for generated native-display config |

`DET_DRM_CARD` is emitted by recon but is not yet wired through every native
display consumer. It must not be advertised as complete portability.

`recon/recon.sh` now records identity, backlights, network interfaces, power
supplies, and DRM connectors and emits `device.conf` beside the raw report.
Review that file before installing it; recon does not guess vendor quirks.

`recon/classify.py` converts the raw report into `capabilities.conf` and a
human-readable `compatibility.txt`. It classifies composer, mapper, allocator,
GPU, binder, DRM, kernel requirements, and boot layout. Unsupported composer
APIs and missing hardware identities are blockers; kernel rebuilds and unproven
GPU or boot paths are reported as explicit porting work.

Before every guest start, `generate-lxc-config` rebuilds the runtime LXC config
from `config.base`. It selects binderfs or direct binder sources, canonicalises
them inside the guest, and includes only device families present on the phone:
KGSL, Mali, PowerVR, Vivante, ashmem/ION/dma-heaps, DRM, input, audio, and legacy
graphics. Uncommon nodes can be supplied through `DET_EXTRA_DEVICES`. The exact
result is recorded in `/data/determination/lxc/device-manifest`.

Known profiles live in `device-profiles/`. The Magisk installer selects a
profile only on an exact `ro.product.device` match. Unknown phones retain
runtime discovery rather than inheriting OnePlus-specific values.

## Portability axes

| Axis | Classes to support | Current state |
|---|---|---|
| Composer | HIDL 2.x, AIDL composer3 | HIDL 2.x proven; AIDL unsupported |
| Allocator | gralloc3/4, mapper3/4, AHardwareBuffer | QTI gralloc4 proven |
| GPU | Adreno vendor EGL, Turnip/KGSL, Mali, PowerVR | Adreno a6xx proven |
| Display | HWC exclusive, native DRM exclusive, Android presenter external | first two proven on SM8150 |
| Kernel | vendor 4.x through modern GKI | 4.14 proven; fragment partly generic |
| Input | evdev + `EVIOCGRAB`, uinput return path | evdev handoff proven |
| Boot | A/B boot image layouts, vendor_boot/init_boot | legacy A/B boot proven |

## Next implementation slices

1. Generate the remaining guest display metadata: DT compatibles, touch-to-
   output mapping, rotation, and panel cutout geometry.
2. Split quirks into independently selected classes (kernel, GPU blob,
   composer, display driver), with explicit probes and failure messages.
3. Make kernel building consume a device build manifest rather than the
   guacamoleb source tree and captured config.
4. Port a second phone chosen to invalidate assumptions: preferably AIDL
   composer or Mali on a modern GKI kernel.

The acceptance test is not “the profile file exists.” A clean recon must
produce configuration that reaches a guest shell, renders a smoke frame,
hands input over, and restores Android without hand-editing scripts.
