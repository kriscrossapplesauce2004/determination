---
name: det-buildflash
description: >-
  Build, repack, flash, restore, and verify the Determination kernel / boot.img
  on the OnePlus 7. Use for kernel builds, boot.img repack via magiskboot, the
  usb-install / host-flash flash+restore+verify flow, OTA recovery, and the
  backup discipline that keeps a bricked flash recoverable. Triggers: build
  kernel, repack boot.img, flash, restore boot, magiskboot, usb-install,
  host-flash, kernel config, OTA wiped the kernel.
---

# Kernel build & flash (Determination)

## Build the kernel — `kernel/build.sh`

Bases the config on the **currently running** kernel's config (`/proc/config.gz`
→ `artifacts/kernel-config-full*.txt`), merges `kernel/determination.config`,
**verifies every option took**, then compiles. ~4 min on this box.

- Toolchain: distro clang + aarch64 binutils in `toolchain/` (gitignored).
  If missing, re-extract the Arch `aarch64-linux-gnu-binutils` package there
  (no root needed). Tree carries the ACK `LLVM=` backport.
- **Clang-version caveat:** the shipping kernel used AOSP clang 21; we build
  with distro clang 22. New `-Werror` warnings are a toolchain artifact — fix
  with `-Wno-…` via `KCFLAGS`, **not** by "fixing" the code.
- `dtbo` is **not** rebuilt — the ROM's flashed dtbo pairs with a same-source
  kernel.

## Repack — `boot/repack.sh`

Swaps the built kernel into the stock `boot.img` with **magiskboot** (needs
`toolchain/usr/bin` on PATH — extract magiskboot from the Magisk apk if
missing). The ramdisk is left for Magisk to patch.

## Flash / restore / verify

Two paths, both cable-optional:

- **Host-driven over adb** (has a host-side backup copy):
  `usb-install/host-flash.sh check | flash | restore | verify`
- **On-device Magisk action zips** (`dd` the boot partition from the phone
  itself): `./det publish` → Magisk app → Modules → Install from storage
  (OTG drive or `/sdcard/Download`). **Dry-run safe mode:**
  `touch /sdcard/Download/determination-dryrun`.

**Backup discipline (non-negotiable — this is the way back from a bad flash):**
before flashing, keep the current boot in all three places — on the phone
(`/sdcard/Download/boot_*-before-*.img`), on the host (`artifacts/backups/`,
gitignored), and a committed pristine `artifacts/boot_<slot>-<rom>.img`. The
restore zip embeds it. Flash to a slot with a way back; the USB cable enables
fastboot rescue.

**After every flash:** `host-flash.sh verify` (asserts all determination
options are present) + a hardware smoke test. WiFi is **built-in (`=y`)** in
the current kernel — `magisk-module-wlan/` kmods overlay is **obsolete**, do
not reship it.

## OTA hazard (bit us on 2026-07-03)

An OTA can switch the active slot, replace the Determination kernel with stock,
**and wipe all Magisk modules**. Recovery: rebuild the kernel against the
**new** running config (a fresh `artifacts/kernel-config-full-<rom>.txt`), then
reflash + reinstall the module.

## Kernel #4

`CONFIG_PSTORE` + `PSTORE_RAM`/`RAMOOPS` are enabled and running. After a panic,
collect the ramoops records before another boot overwrites useful evidence.
Live `dmesg -w` capture is still worthwhile during risky display/kernel work.

Reach the device via `[[det-phone]]`; guest graphics debugging is `[[det-guest]]`.
