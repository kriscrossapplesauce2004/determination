#!/system/bin/sh
# DecemberOS kernel RESTORE — flashes the embedded pristine boot image back.
# The embedded boot.img is a dump of the active boot slot taken right before
# the DecemberOS kernel install: stock crDroid kernel with the Magisk-patched
# ramdisk — i.e. exactly the known-good state, root included. Which slot that
# is gets baked in at zip build time (see @SLOT@ below).
#
# Checks before writing: slot guard, boot-image magic, embedded size +
# sha256, battery >= 15%, free space for a backup of the CURRENT boot
# (taken and sha-verified first, so the restore itself is undoable),
# no-op guard if the partition already matches, readback verify after.
#
# SAFE MODE / DRY RUN: create /sdcard/Download/decemberos-dryrun and flash
# this zip — every check runs (including the backup) but the partition is
# not written. Delete the flag file to arm the real restore.
#
# Only usable while Android still boots (the Magisk app has to run to flash
# this). If the phone is bootlooping, this zip cannot help — that needs a
# cable (fastboot flash of the pristine dump in artifacts/, or EDL).

SKIPUNZIP=1

# Substituted at zip build time from the pristine image being embedded.
WANT_SHA=@SHA256@
IMGSIZE=@SIZE@
WANT_SLOT=@SLOT@

DRYFLAG=/sdcard/Download/decemberos-dryrun

fail() { ui_print ""; ui_print "!!! $1"; abort "aborting"; }

DRYRUN=false
[ -f "$DRYFLAG" ] && DRYRUN=true && ui_print "- DRY RUN (found $DRYFLAG): all checks, no flash"

slot=$(getprop ro.boot.slot_suffix)
[ "$slot" = "$WANT_SLOT" ] || fail "active slot is '$slot', but this image is a boot$WANT_SLOT dump — refusing"
part=/dev/block/bootdevice/by-name/boot$slot
[ -e "$part" ] || fail "boot partition not found at $part"
partsize=$(blockdev --getsize64 "$part") || fail "cannot read partition size"
[ "$IMGSIZE" -le "$partsize" ] || fail "embedded image ($IMGSIZE) larger than partition ($partsize)"

# --- battery preflight ----------------------------------------------------
batt=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
[ -n "$batt" ] || batt=$(dumpsys battery 2>/dev/null | awk '/level:/{print $2; exit}')
if [ -n "$batt" ]; then
    [ "$batt" -ge 15 ] 2>/dev/null || fail "battery at ${batt}% — charge to at least 15% first"
    ui_print "- Battery: ${batt}%"
else
    ui_print "- Battery level unreadable — continuing"
fi

# --- extract + verify the embedded pristine image --------------------------
ui_print "- Extracting embedded pristine boot image"
img=$TMPDIR/restore-boot.img
unzip -p "$ZIPFILE" boot.img > "$img" || fail "could not extract boot.img from zip"

[ "$(head -c 8 "$img")" = "ANDROID!" ] || fail "embedded image is not an Android boot image — zip corrupt"
[ "$(stat -c%s "$img")" = "$IMGSIZE" ] || fail "extracted image has wrong size"
got=$(sha256sum "$img" | cut -d' ' -f1)
[ "$got" = "$WANT_SHA" ] || fail "extracted image checksum mismatch — zip corrupt, do not flash"
ui_print "- Checksum verified"

# --- no-op guard ------------------------------------------------------------
cur=$(head -c "$IMGSIZE" "$part" | sha256sum | cut -d' ' -f1)
if [ "$cur" = "$WANT_SHA" ]; then
    ui_print ""
    ui_print "- boot$slot ALREADY holds the pristine image — nothing to do."
    abort "NOT AN ERROR — partition already matches; nothing was written"
fi

# --- back up the CURRENT boot first (restore is undoable too) ---------------
ts=$(date +%Y%m%d-%H%M%S)
bdst=""
for d in /mnt/media_rw/*; do
    [ -d "$d" ] && touch "$d/.dos-wtest" 2>/dev/null && rm -f "$d/.dos-wtest" && bdst="$d" && break
done
[ -n "$bdst" ] || bdst=/sdcard/Download

freek=$(df -Pk "$bdst" 2>/dev/null | awk 'NR==2{print $4}')
needk=$(( partsize / 1024 + 20480 ))
if [ -n "$freek" ] && [ "$freek" -lt "$needk" ]; then
    fail "only ${freek}K free at $bdst — need ${needk}K for the pre-restore backup"
fi

backup="$bdst/boot${slot}-before-restore-$ts.img"
ui_print "- Backing up current boot$slot -> $backup"
dd if="$part" of="$backup" bs=1048576 2>/dev/null || fail "backup dd failed"
sync
psha=$(sha256sum "$part" | cut -d' ' -f1)
bsha=$(sha256sum "$backup" | cut -d' ' -f1)
[ "$psha" = "$bsha" ] || fail "backup does not match the partition (sha mismatch) — refusing to restore without a good backup"
ui_print "- Backup verified"

# --- dry-run stop -------------------------------------------------------------
if $DRYRUN; then
    ui_print ""
    ui_print "*******************************************"
    ui_print "  DRY RUN COMPLETE — every check passed."
    ui_print "  A verified backup of the current boot is"
    ui_print "  at: $backup"
    ui_print "  Nothing was written to $part."
    ui_print "  Delete $DRYFLAG and reflash to restore."
    ui_print "*******************************************"
    abort "NOT AN ERROR — dry run finished; nothing was flashed"
fi

# --- flash + readback verify ----------------------------------------------------
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
ui_print "  The DecemberOS boot you just replaced is"
ui_print "  backed up at: $backup"
ui_print "*******************************************"
ui_print ""
abort "NOT AN ERROR — restore succeeded; this zip intentionally installs no module"
