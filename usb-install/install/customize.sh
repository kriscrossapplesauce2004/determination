#!/system/bin/sh
# DecemberOS kernel installer — an "action zip" for the Magisk app.
#
# Flow (all on the phone, no PC, no cable):
#   1. Magisk app -> Install -> Select and Patch a File -> pick
#      decemberos-boot.img from the USB drive. Output lands in
#      /sdcard/Download/magisk_patched-XXXXX.img.
#   2. Magisk app -> Modules -> Install from storage -> pick THIS zip.
#      It finds the newest magisk_patched-*.img, verifies the kernel inside
#      is actually the DecemberOS build, backs up the current boot slot,
#      dd's the patched image in, and verifies the readback.
#   3. Reboot. `uname -a` should say melissa@terra.
#
# It aborts at the end ON PURPOSE so Magisk does not register it as a module
# — the flash has already happened by then.

SKIPUNZIP=1

# Kernel identity marker: the version string baked into the DecemberOS build.
MARKER="melissa@terra"

MB=/data/adb/magisk/magiskboot
BB=/data/adb/magisk/busybox

fail() { ui_print ""; ui_print "!!! $1"; abort "aborting — nothing was flashed"; }

slot=$(getprop ro.boot.slot_suffix)
part=/dev/block/bootdevice/by-name/boot$slot
[ -e "$part" ] || fail "boot partition not found at $part"
[ -x "$MB" ] || fail "magiskboot not found at $MB"

ui_print "- Active slot: ${slot:-none}, target: $part"

# Newest Magisk-patched image in Download — the app always writes there.
img=$(ls -t /sdcard/Download/magisk_patched-*.img 2>/dev/null | head -n1)
[ -n "$img" ] || fail "no magisk_patched-*.img in /sdcard/Download.
    First patch decemberos-boot.img:
    Magisk app -> Install -> Select and Patch a File"
ui_print "- Patched image: $img"

imgsize=$(stat -c%s "$img")
partsize=$(blockdev --getsize64 "$part")
[ "$imgsize" -le "$partsize" ] || fail "image ($imgsize) larger than partition ($partsize)"

# Verify the kernel inside really is the DecemberOS build before touching
# anything — a stock magisk_patched image would silently undo the kernel.
vdir=$TMPDIR/dos-verify
rm -rf "$vdir"; mkdir -p "$vdir"
(cd "$vdir" && "$MB" unpack "$img" >/dev/null 2>&1) || fail "magiskboot could not unpack $img"
[ -f "$vdir/kernel" ] || fail "no kernel found inside $img"
if ! grep -q "$MARKER" "$vdir/kernel" 2>/dev/null; then
    fail "kernel inside $img is NOT the DecemberOS build
    (marker '$MARKER' missing). Did you patch the right file?
    Patch decemberos-boot.img from the USB drive, then re-flash this zip."
fi
ui_print "- Verified: kernel inside the image is the DecemberOS build"
rm -rf "$vdir"

# Back up the current boot slot before writing. Prefer the USB drive so the
# backup survives the phone; fall back to Download.
ts=$(date +%Y%m%d-%H%M%S)
bdst=""
for d in /mnt/media_rw/*; do
    [ -d "$d" ] && touch "$d/.dos-wtest" 2>/dev/null && rm -f "$d/.dos-wtest" && bdst="$d" && break
done
[ -n "$bdst" ] || bdst=/sdcard/Download
backup="$bdst/boot${slot}-before-decemberos-$ts.img"
ui_print "- Backing up current boot$slot -> $backup"
dd if="$part" of="$backup" bs=1048576 2>/dev/null || fail "backup dd failed"
sync

ui_print "- Flashing $img -> boot$slot"
dd if="$img" of="$part" bs=1048576 2>/dev/null || fail "FLASH dd FAILED — do not reboot; flash the restore zip now"
sync

# Readback verify: first $imgsize bytes of the partition must match the image.
want=$(sha256sum "$img" | cut -d' ' -f1)
got=$(head -c "$imgsize" "$part" | sha256sum | cut -d' ' -f1)
if [ "$want" != "$got" ]; then
    fail "readback mismatch after flash — do NOT reboot.
    Flash decemberos-kernel-restore.zip from this same USB drive now."
fi

ui_print ""
ui_print "*******************************************"
ui_print "  DecemberOS kernel flashed and verified."
ui_print "  Backup of the old boot: $backup"
ui_print "  Reboot now. After boot, uname -a should"
ui_print "  contain: $MARKER"
ui_print "  If it bootloops: it will NOT recover on"
ui_print "  its own — a USB cable + fastboot/EDL is"
ui_print "  the only way back. See usb-install/README."
ui_print "*******************************************"
ui_print ""
abort "NOT AN ERROR — flash succeeded; this zip intentionally installs no module"
