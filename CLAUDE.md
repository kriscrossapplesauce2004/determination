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
- No cable still means no fastboot — but there IS a cable-free install path
  now: `usb-install/` builds Magisk "action zips" that `dd` the boot
  partition from the phone itself (Magisk app → Modules → Install from
  storage). `./dos publish` pushes `dist/usb-payload/` to an OTG USB drive.
  The one unrecoverable-without-cable scenario is the new kernel
  bootlooping (restore zip needs a booted phone); melissa accepted that
  trade knowingly — see usb-install/README.md "honest risk paragraph".

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

Flash-day ready as of 2026-07-01 night (see docs/flash-day.md — the runbook):
kernel built (3m13s on this box), `boot/decemberos-boot.img` repacked from the
dumped boot_b (`artifacts/boot_b-crdroid-12.10.img` = the pristine restore
image) and verified; module zip packaged with static aarch64 evgrab; `./dos`
host helper wraps the wireless-adb workflow. Official platform-tools persisted
at `~/platform-tools`. magiskboot + aarch64 gcc/glibc live in `toolchain/`
(gitignored; re-extract Arch pkgs if missing).

Still missing before desktop-on can show anything (post-flash work):
1. Static arm64 LXC build for the Android host side (`/data/decemberos/lxc/bin`).
2. Guest rootfs (`guest/build-rootfs.sh` — mmdebstrap not installed on host yet).
3. A wlroots compositor with the hwcomposer backend — stock Debian sway can
   NOT drive hwcomposer; Droidian's packages (or a hybris-wlroots build) are
   required. The libhybris `test_hwcomposer` smoke test gates everything.
Until those land, desktop-on would stop SF and leave the panel dark with no
touch (recover via `./dos shell /data/decemberos/bin/desktop-off`).
