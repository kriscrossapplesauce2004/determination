# Determination — kernel install (action zips + host script)

Three ways in, safest first:

1. **Action zips on the phone** (no PC needed): Magisk app flashes the boot
   partition directly, exactly like its own Direct Install. This file mostly
   documents that path.
2. **`host-flash.sh` over the USB cable**: same checks driven from the PC
   (`check` / `flash` / `restore` / `verify`), with one extra safety layer —
   the pre-flash backup is also pulled to the PC (`artifacts/backups/`).
   Magisk-patching the image stays in the app; everything else is scripted.
3. **fastboot** (cable, last resort): `fastboot flash boot
   artifacts/boot_a-crdroid-12.11.img` recovers even a bootloop.

## Checks and safe modes (v0.2.x zips)

Before a single byte is written, the install zip verifies: boot-image magic,
size fit, **the exact kernel build** (full version banner incl. build
timestamp — a stale `magisk_patched` from an older build is rejected on the
spot), **that the ramdisk is Magisk-patched** (flashing an unpatched image
would boot but silently remove root — and root is the only way back),
battery ≥ 15%, free space for the backup, and the backup itself is
sha256-verified against the partition. After writing it verifies the
readback; if the partition already holds the exact image it stops as a
no-op. It scans all `magisk_patched-*.img` newest-first and takes the first
one that passes, printing why others were rejected.

**Dry run**: `touch /sdcard/Download/determination-dryrun`, then flash either
zip — every check runs, a verified backup is taken, nothing is written to
the partition. Delete the flag file to arm the real flash. (`host-flash.sh
check` is the same idea from the PC.)

The restore zip additionally backs up the current (Determination) boot before
restoring, so the restore is itself undoable.

## What's on the drive (`dist/usb-payload/`)

| File | What |
|---|---|
| `determination-boot.img` | stock boot image of the active slot with the Determination kernel swapped in (NOT yet Magisk-patched) |
| `determination-kernel-install.zip` | action zip: flashes the patched image to the active slot |
| `determination-kernel-restore.zip` | action zip: flashes the embedded pristine boot dump back (stock kernel + root; slot-guarded) |
| `determination-magisk-v*.zip` | the actual Determination Magisk module (toggle scripts, evgrab, sepolicy) |
| `SHA256SUMS` | checksums for everything above |

## Install (3 steps, all in the Magisk app)

1. **Patch**: Magisk → Install → *Select and Patch a File* → pick
   `determination-boot.img` from the USB drive. Output appears as
   `/sdcard/Download/magisk_patched-XXXXX.img`.
2. **Flash**: Magisk → Modules → *Install from storage* → pick
   `determination-kernel-install.zip` from the drive. It finds the newest
   `magisk_patched-*.img`, **verifies the kernel inside is really the
   Determination build** (refuses anything else), backs up the current boot
   partition to the drive, flashes, and verifies the readback.
   It ends with an "abort" — **that is deliberate** (it's how an action zip
   avoids registering as a module). Read the log above it: if it says
   `flashed and verified`, it worked.
3. **Reboot.** Check with any terminal / `adb shell`: `uname -a` must contain
   `melissa@terra`. Then install the `determination-magisk-v*.zip` the same way
   (Modules → Install from storage) — this one is a real module and stays.

## Undo

Magisk → Modules → Install from storage → `determination-kernel-restore.zip`.
Restores the exact pre-Determination boot image of the slot it was dumped from
(stock crDroid kernel, still rooted; refuses to flash if the active slot
does not match). Verified by embedded sha256 before and after writing.

## The honest risk paragraph

The install itself is safe *while Android boots*: every step is verified, a
backup is taken first, and the restore zip undoes it in one flash. The one
scenario neither zip can fix is **the new kernel failing to boot** — the
restore zip needs a running Magisk app. A bootloop there needs a USB cable:
`fastboot flash boot artifacts/boot_a-crdroid-12.11.img` (or MSM/EDL as last
resort). As of 2026-07-03 a cable exists, so this is a recoverable state,
not a dead phone. The kernel was built from crDroid's own 16.0 tree with the
running kernel's exact config as base, so the risk of hitting it is low.
