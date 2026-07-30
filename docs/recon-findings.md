# Recon findings : guacamoleb, 2026-07-01

Raw data: `recon/report-20260701-232516/` and `artifacts/` (full kernel
config, ROM identity). Collected over wireless adb + Magisk su.

## The device is NOT stock : and that's fine

- **ROM:** crDroid **12.10** (Android **16**, SDK 36), build `v12.10-20260520`,
  slot `_b`. Fingerprint is spoofed to stock OnePlus Android 12, which is why
  it looks stock at first glance.
- **Kernel:** `4.14.357-openela-perf`, built 2026-05-03 with AOSP clang 21 :
  crDroid's sm8150 fork with OpenELA extended-LTS merges.
- **Magisk 30.7** rooted, `su` works from adb shell (grant "Shell" in the
  Superuser tab : it silently denies otherwise).

Consequences for the design: the spec's "keep `/system`/`/vendor` stock"
becomes "keep the crDroid install untouched" : same architecture, and we
rebuild the kernel from **crDroid's fork** (kernel/fetch.sh updated) so the
only delta vs. the running kernel is our container fragment. Zygisk hooks
(milestone 6) target Android 16 framework, not 12.

## Graphics: exactly the well-trodden path

- Composer HAL: **HIDL `graphics.composer@2.1–2.4`** (service
  `vendor.hwcomposer-2-4`, pid 1192, backed by `hwcomposer.qcom.so`). No AIDL
  composer3 : libhybris's HIDL hwcomposer backend applies.
- Gralloc/allocator: QTI **allocator@3.0 + @4.0** both registered, with
  matching `mapper@3.0` / `mapper@4.0` vendor impls. Nearly every process maps
  through mapper@4.0 → pair libhybris as **gralloc4/mapper 4.0**.
- `/dev/kgsl-3d0` (a6xx), `/dev/ion`, and : bonus : real DRM nodes
  (`/dev/dri/card0`, `renderD128`, `CONFIG_DRM_MSM=y`). libhybris/hwcomposer
  remains the primary plan; the DRM nodes are a fallback experiment only.

## Kernel: rebuild still required, but smaller than planned

Already present: `NAMESPACES`, `UTS_NS`, `NET_NS`, `MEMCG`, `VETH`, `BRIDGE`,
NAT/MASQUERADE, `ASHMEM`, `OVERLAY_FS`, `FUSE_FS`, `SECCOMP_FILTER`, and
**`ANDROID_BINDERFS=y`** : `/dev/binderfs` is live with `binder-control`, and
`/dev/binder` etc. are symlinks into it. The guest therefore gets private
binder contexts via a fresh binderfs instance in its IPC namespace (LXC config
updated; the extra-binder-devices plan is dropped).

Missing (what `kernel/determination.config` adds): **`PID_NS`** (hard LXC
requirement), `IPC_NS` (needed for the private binderfs instance), `USER_NS`,
`CGROUP_DEVICE`, `CGROUP_PIDS`, `POSIX_MQUEUE`.

## Input

14 evdev nodes (`event0–12` + dir), root:input 0660 : fine for `evgrab` as
root and for the guest via the `input` group.

## Init services (toggle targets confirmed)

`init.svc.surfaceflinger=running`, `init.svc.vendor.hwcomposer-2-4=running`
(separate processes : SF is the *client* we stop; the vendor composer service
keeps running through the handoff, as the toggle assumes), `bootanim=stopped`,
zygote + zygote_secondary running.

## Wireless adb notes

- Distro `android-tools` adb (35.0.2) has broken pairing; use official
  platform-tools.
- `adb root` restarts adbd and drops wireless transports : recon.sh now
  prefers `su -c` (fixed).
- Port rotates on every wireless-debugging toggle/reboot; rediscover with
  `adb mdns services`.

## DP-alt confirmed working (user-verified, 2026-07-01)

DisplayPort over USB-C works on this hardware/ROM : crDroid enables what
stock OnePlus never did. Android's native desktop mode runs on it (buggy, but
functional). Consequences:

- §5 external convergence's only hardware risk (DP-alt enumeration) is gone;
  what remains is pointing the guest compositor at the external hwcomposer
  display instead of Android.
- The composer HAL demonstrably handles a second concurrent display on this
  device : good news for hotplug paths in the wlroots backend.
- Native desktop mode working means the A16 desktop/freeform framework paths
  are alive on this ROM: the §6 flag flips / WMS hooks have a working
  substrate, and "buggy native desktop" is the benchmark our guest desktop
  has to beat (a real Debian desktop clears that bar easily).
