# DecemberOS — install from the phone itself (no PC, no cable)

Everything in this folder happens **on the phone**, using the Magisk app and
a USB drive (or just files in Download). No fastboot involved: Magisk root
writes the boot partition directly, exactly like the app's own Direct Install.

## What's on the drive (`dist/usb-payload/`)

| File | What |
|---|---|
| `decemberos-boot.img` | stock boot image of the active slot with the DecemberOS kernel swapped in (NOT yet Magisk-patched) |
| `decemberos-kernel-install.zip` | action zip: flashes the patched image to the active slot |
| `decemberos-kernel-restore.zip` | action zip: flashes the embedded pristine boot dump back (stock kernel + root; slot-guarded) |
| `decemberos-magisk-v*.zip` | the actual DecemberOS Magisk module (toggle scripts, evgrab, sepolicy) |
| `SHA256SUMS` | checksums for everything above |

## Install (3 steps, all in the Magisk app)

1. **Patch**: Magisk → Install → *Select and Patch a File* → pick
   `decemberos-boot.img` from the USB drive. Output appears as
   `/sdcard/Download/magisk_patched-XXXXX.img`.
2. **Flash**: Magisk → Modules → *Install from storage* → pick
   `decemberos-kernel-install.zip` from the drive. It finds the newest
   `magisk_patched-*.img`, **verifies the kernel inside is really the
   DecemberOS build** (refuses anything else), backs up the current boot
   partition to the drive, flashes, and verifies the readback.
   It ends with an "abort" — **that is deliberate** (it's how an action zip
   avoids registering as a module). Read the log above it: if it says
   `flashed and verified`, it worked.
3. **Reboot.** Check with any terminal / `adb shell`: `uname -a` must contain
   `melissa@terra`. Then install the `decemberos-magisk-v*.zip` the same way
   (Modules → Install from storage) — this one is a real module and stays.

## Undo

Magisk → Modules → Install from storage → `decemberos-kernel-restore.zip`.
Restores the exact pre-DecemberOS boot image of the slot it was dumped from
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
