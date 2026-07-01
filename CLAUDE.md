# DecemberOS — project context

Android convergence layer for melissa's OnePlus 7 (`guacamoleb`, SM8150 /
Adreno 640). Android stays PID1 and live; a Debian LXC guest on the same
downstream kernel takes the display via libhybris→hwcomposer. Ships as custom
boot.img + Magisk module + Zygisk — never a ROM, never touches /system.

**Read first:** `docs/design-spec.md` (the authoritative design — §4 internal
panel handoff is the core novel work) and `docs/recon-findings.md` (ground
truth about the actual device). `README.md` has the repo map and milestone
order. Raw probe outputs live in `recon/report-*/` and `artifacts/`.

## The device (recon-verified 2026-07-01, don't re-derive)

- crDroid 12.10 / Android 16 (SDK 36) — NOT stock; fingerprint is spoofed to
  OnePlus Android 12. Slot `_b`. Magisk 30.7.
- Kernel `4.14.357-openela` from crDroid's sm8150 fork (branch `16.0`).
- Composer HAL: HIDL `graphics.composer@2.1–2.4` (no AIDL composer3).
  Gralloc: QTI mapper@4.0 → libhybris pairs as gralloc4.
- binderfs already in the running kernel; guest gets a private binderfs
  instance in its IPC ns (do NOT resurrect the extra-binder-devices idea).
- Kernel opts we must add (why the rebuild exists): PID_NS, IPC_NS, USER_NS,
  CGROUP_DEVICE, CGROUP_PIDS, POSIX_MQUEUE → `kernel/decemberos.config`.
- DP-alt over USB-C works on this ROM (user-verified); Android's native
  desktop mode runs on it. §5 external convergence has no hardware risk.

## Talking to the phone (wireless adb — there is currently no USB cable)

- Use official platform-tools adb, NOT distro `android-tools` (its pairing is
  broken). If not present, download platform-tools-latest-linux.zip from
  dl.google.com into the scratchpad.
- Port rotates on every reboot/toggle: discover with `adb mdns services`,
  connect to the `_adb-tls-connect` entry. Pairing persists; re-pairing is
  only needed if the phone forgets the host.
- **Never run `adb root`** — it restarts adbd and drops the wireless
  transport. Root is `adb shell su -c ...` (Magisk). If su returns
  "Permission denied" silently, the Shell toggle in Magisk's Superuser tab is
  off — ask melissa to flip it (screen must be unlocked for grant prompts).
- No cable also means: no fastboot, so nothing can be flashed yet, and a
  boot-looping flash could not be rescued. Do not flash anything until a
  cable exists. Flashing is otherwise low-risk: `fastboot boot` (RAM-boot)
  first, A/B slot fallback, MSM/EDL as last resort.

## Build system

- `kernel/build.sh`: bases the config on the RUNNING kernel's config
  (`artifacts/kernel-config-full.txt` from /proc/config.gz), merges
  `decemberos.config`, verifies every option took before compiling. Distro
  clang + aarch64 binutils extracted to `toolchain/` (gitignored — if
  missing, re-extract the Arch `aarch64-linux-gnu-binutils` package there,
  no root needed). Tree has the ACK LLVM= backport.
- Known risk: shipping kernel used AOSP clang 21, we build with distro clang
  22 — new warnings-as-errors may need `-Wno-` additions (KCFLAGS), not real fixes.
- dtbo is NOT rebuilt; the ROM's flashed dtbo pairs with a same-source kernel.
- `boot/repack.sh`: swaps kernel into stock boot.img via magiskboot (not
  installed yet — extract from Magisk apk), ramdisk left for Magisk to patch.
- evgrab (`tools/evgrab/`): builds with `make host CC=clang` for logic tests
  (verified working on host evdev); device build needs NDK or aarch64 gcc.

## Conventions

- Ad-hoc probe/script *outputs* get saved to `artifacts/` with descriptive
  names (melissa's standing request). Structured recon goes to `recon/report-*/`.
- Commit as work lands; author `melissa <theonest262@gmail.com>`.
- The toggle scripts' suppressor loop (desktop-on) is an acknowledged bring-up
  hack; the real fix is the Zygisk SF-death-handler hook (zygisk/README.md).
- Related-but-separate: `~/op7-port/` + pmOS memories are the *mainline*
  kernel track. DecemberOS is deliberately downstream-kernel. Don't mix them.

## State / next steps

1. First kernel build was launched 2026-07-01 late evening (background task,
   `kernel/out/`) — check whether it finished: `ls kernel/out/arch/arm64/boot/`.
   If Image.gz-dtb exists, next is `boot/repack.sh` (needs magiskboot + the
   stock boot.img for the *installed crDroid build* — `~/boot.img` may be
   stale, safer to dump boot_b from the device with su + dd).
2. Then: Magisk-patch, RAM-boot test via `fastboot boot` (cable day),
   verify PID_NS etc. in the booted kernel, then guest bring-up
   (`guest/build-rootfs.sh`, needs mmdebstrap installed).
3. Milestone order and everything else: README.md.
