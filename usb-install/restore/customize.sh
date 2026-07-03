#!/system/bin/sh
# DecemberOS kernel RESTORE — flashes the embedded pristine boot image back.
# The embedded boot.img is a dump of the active boot slot taken right before
# the DecemberOS kernel install: stock crDroid kernel with the Magisk-patched
# ramdisk — i.e. exactly the known-good state, root included. Which slot that
# is gets baked in at zip build time (see @SLOT@ below).
#
# Only usable while Android still boots (the Magisk app has to run to flash
# this). If the phone is bootlooping, this zip cannot help — that needs a
# cable (fastboot flash of the pristine dump in artifacts/, or EDL).

SKIPUNZIP=1

# Substituted at zip build time from the pristine image being embedded.
WANT_SHA=@SHA256@
IMGSIZE=@SIZE@
WANT_SLOT=@SLOT@

fail() { ui_print ""; ui_print "!!! $1"; abort "aborting"; }

slot=$(getprop ro.boot.slot_suffix)
[ "$slot" = "$WANT_SLOT" ] || fail "active slot is '$slot', but this image is a boot$WANT_SLOT dump — refusing"
part=/dev/block/bootdevice/by-name/boot$slot
[ -e "$part" ] || fail "boot partition not found at $part"

ui_print "- Extracting embedded pristine boot image"
img=$TMPDIR/restore-boot.img
unzip -p "$ZIPFILE" boot.img > "$img" || fail "could not extract boot.img from zip"

[ "$(stat -c%s "$img")" = "$IMGSIZE" ] || fail "extracted image has wrong size"
got=$(sha256sum "$img" | cut -d' ' -f1)
[ "$got" = "$WANT_SHA" ] || fail "extracted image checksum mismatch — zip corrupt, do not flash"
ui_print "- Checksum verified"

ui_print "- Flashing pristine boot$WANT_SLOT (stock kernel + Magisk)"
dd if="$img" of="$part" bs=1048576 2>/dev/null || fail "dd failed — do not reboot, retry this zip"
sync

rb=$(head -c "$IMGSIZE" "$part" | sha256sum | cut -d' ' -f1)
[ "$rb" = "$WANT_SHA" ] || fail "readback mismatch — do not reboot, retry this zip"

ui_print ""
ui_print "*******************************************"
ui_print "  Pristine boot restored and verified."
ui_print "  Reboot: phone is back to plain crDroid"
ui_print "  (with root). DecemberOS kernel removed."
ui_print "*******************************************"
ui_print ""
abort "NOT AN ERROR — restore succeeded; this zip intentionally installs no module"
