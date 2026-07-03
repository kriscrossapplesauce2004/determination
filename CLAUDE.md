# DecemberOS — project context

Android convergence layer for melissa's OnePlus 7 (`guacamoleb`, SM8150 /
Adreno 640). Android stays PID1 and live; a Debian LXC guest on the same
downstream kernel takes the display via libhybris→hwcomposer. Ships as custom
boot.img + Magisk module + Zygisk — never a ROM, never touches /system.

**Read first:** `docs/design-spec.md` (the authoritative design — §4 internal
panel handoff is the core novel work) and `docs/recon-findings.md` (ground
truth about the actual device). `README.md` has the repo map and milestone
order. Raw probe outputs live in `recon/report-*/` and `artifacts/`.

## The device (recon-verified 2026-07-01, updated 2026-07-03, don't re-derive)

- crDroid 12.11 / Android 16 (SDK 36) — NOT stock; fingerprint is spoofed to
  OnePlus Android 12. Slot `_a` (the 2026-07-03 OTA switched slots). Magisk
  30.7. The OTA replaced the DecemberOS kernel with stock and wiped all
  Magisk modules — see State below.
- Kernel `4.14.357-openela` from crDroid's sm8150 fork (branch `16.0`).
- Composer HAL: HIDL `graphics.composer@2.1–2.4` (no AIDL composer3).
  Gralloc: QTI mapper@4.0 → libhybris pairs as gralloc4.
- binderfs already in the running kernel; guest gets a private binderfs
  instance in its IPC ns (do NOT resurrect the extra-binder-devices idea).
- Kernel opts we must add (why the rebuild exists): PID_NS, IPC_NS, USER_NS,
  CGROUP_DEVICE, CGROUP_PIDS, POSIX_MQUEUE → `kernel/decemberos.config`.
- DP-alt over USB-C works on this ROM (user-verified); Android's native
  desktop mode runs on it. §5 external convergence has no hardware risk.

## Talking to the phone (USB cable exists as of 2026-07-03)

- A USB cable now connects the phone (`adb devices` shows it on usb) —
  fastboot recovery is possible, so a kernel bootloop is no longer a
  dead-phone scenario. Wireless adb still works as fallback: official
  platform-tools only (distro `android-tools` pairing is broken), port
  rotates per reboot, discover via `adb mdns services`.
- **Never run `adb root`**. Root is `adb shell su -c ...` (Magisk). If su
  returns "Permission denied" silently, the Shell toggle in Magisk's
  Superuser tab is off — ask melissa to flip it (screen must be unlocked
  for grant prompts).
- Install path is the `usb-install/` Magisk "action zips" that `dd` the
  boot partition from the phone itself (Magisk app → Modules → Install from
  storage). Payload can go to an OTG drive (`./dos publish`) or straight to
  `/sdcard/Download` via adb push — the Magisk app can install from either.
  Cable alternative: `usb-install/host-flash.sh check|flash|restore|verify`
  drives the same flow over adb with a host-side backup copy; dry-run safe
  mode for the zips = `touch /sdcard/Download/decemberos-dryrun`.

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

**2026-07-03 evening: MILESTONE 1 RESTORED — kernel #3 is flashed and
running on crDroid 12.11.** `/proc/version` = `4.14.357-perf-g96adfa8256dc
(melissa@terra) … Fri Jul 3 18:32:22 BST 2026`; `host-flash.sh verify`
green (all DecemberOS options incl. VT/nftables/CRIU/binfmt_misc/macvlan);
WiFi green on the BUILT-IN driver (5 GHz 11ac, no kmods overlay); module
v0.1.2 installed, IPv6 forwarding on. Backups of the pre-flash boot:
`/sdcard/Download/boot_a-before-decemberos-20260703-185113.img` (on phone),
`artifacts/backups/` (host, gitignored), `artifacts/boot_a-crdroid-12.11.img`
(committed pristine — all three sha-identical), plus the restore zip embeds
it. Earlier that day: the 12.11 OTA had switched to slot `_a`, replaced
kernel #1 with stock, and wiped all Magisk modules; kernel #3 was rebuilt
from a clean `kernel/out` against the new running config
(`artifacts/kernel-config-full-12.11.txt`).

Kernel #3 has QCA_CLD_WLAN/GSPCA **built in** (=y) — the kmods overlay
(`magisk-module-wlan/`, keyed to kernel #1's exact uname) is obsolete; do
not reship it. The old "must rebuild modules or WiFi dies" rule is dead:
decemberos.config has no =m options.

MILESTONE 1 (2026-07-02, pre-OTA): kernel #1 flashed cable-free via the
`usb-install/` action zips and ran (`4.14.357-perf-g96adfa8256dc`); WiFi
vermagic gotcha found and fixed, hardware smoke test green.

Toolchain context: `boot/repack.sh` needs magiskboot from
`toolchain/usr/bin` on PATH; platform-tools at `~/platform-tools`;
toolchain/ gitignored (re-extract Arch pkgs if missing). Kernel build:
~4 min on this box.

Still missing before desktop-on can show anything (post-flash work):
1. Static arm64 LXC build for the Android host side (`/data/decemberos/lxc/bin`).
2. Guest rootfs (`guest/build-rootfs.sh` — mmdebstrap not installed on host yet).
3. A wlroots compositor with the hwcomposer backend — stock Debian sway can
   NOT drive hwcomposer; Droidian's packages (or a hybris-wlroots build) are
   required. The libhybris `test_hwcomposer` smoke test gates everything.
Until those land, desktop-on would stop SF and leave the panel dark with no
touch (recover via `./dos shell /data/decemberos/bin/desktop-off`).
