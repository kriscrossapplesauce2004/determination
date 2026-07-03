#!/system/bin/sh
# DecemberOS kernel installer — an "action zip" for the Magisk app.
#
# Flow (all on the phone, no PC needed):
#   1. Magisk app -> Install -> Select and Patch a File -> pick
#      decemberos-boot.img from the USB drive / Download. Output lands in
#      /sdcard/Download/magisk_patched-XXXXX.img.
#   2. Magisk app -> Modules -> Install from storage -> pick THIS zip.
#      It scans Download for magisk_patched-*.img (newest first) and flashes
#      the first one that passes ALL checks; see the check list below.
#   3. Reboot. `uname -a` should say melissa@terra.
#
# Checks before a single byte is written to the partition:
#   - image is a real Android boot image (ANDROID! magic)
#   - image fits the partition
#   - kernel inside is THIS exact DecemberOS build (full version banner,
#     including build timestamp — a stale patched image from an older
#     build fails here, not at boot)
#   - ramdisk is Magisk-patched (flashing an unpatched image would boot
#     but silently remove root — and root is the only way back)
#   - battery >= 15%
#   - backup destination has room; backup is taken and its sha256 is
#     verified against the partition BEFORE flashing
#   - no-op guard: if the partition already holds this exact image, stop
#
# SAFE MODE / DRY RUN: create the flag file
#     /sdcard/Download/decemberos-dryrun
# (e.g. `touch` it from a terminal) and flash this zip. It runs every
# check above INCLUDING taking + verifying the backup, then stops without
# writing the boot partition. Delete the flag file to arm the real flash.
#
# It aborts at the end ON PURPOSE so Magisk does not register it as a module
# — the flash (or dry run) has already happened by then.

SKIPUNZIP=1

# Kernel identity: full banner of the exact build this payload ships,
# substituted at zip build time. Falls back to the project marker if the
# substitution somehow did not happen.
BANNER="@BANNER@"
MARKER="melissa@terra"
case "$BANNER" in @*) BANNER="$MARKER" ;; esac

DRYFLAG=/sdcard/Download/decemberos-dryrun

MB=/data/adb/magisk/magiskboot

fail() { ui_print ""; ui_print "!!! $1"; abort "aborting — nothing was flashed"; }

DRYRUN=false
[ -f "$DRYFLAG" ] && DRYRUN=true && ui_print "- DRY RUN (found $DRYFLAG): all checks, no flash"

slot=$(getprop ro.boot.slot_suffix)
part=/dev/block/bootdevice/by-name/boot$slot
[ -e "$part" ] || fail "boot partition not found at $part"
[ -x "$MB" ] || fail "magiskboot not found at $MB"
partsize=$(blockdev --getsize64 "$part") || fail "cannot read partition size"

ui_print "- Active slot: ${slot:-none}, target: $part"

# --- battery preflight --------------------------------------------------
batt=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
[ -n "$batt" ] || batt=$(dumpsys battery 2>/dev/null | awk '/level:/{print $2; exit}')
if [ -n "$batt" ]; then
    [ "$batt" -ge 15 ] 2>/dev/null || fail "battery at ${batt}% — charge to at least 15% first"
    ui_print "- Battery: ${batt}%"
else
    ui_print "- Battery level unreadable — continuing"
fi

# --- pick a patched image: newest first, first one that passes ----------
vdir=$TMPDIR/dos-verify
img=""
for cand in $(ls -t /sdcard/Download/magisk_patched-*.img 2>/dev/null); do
    ui_print "- Checking candidate: $cand"
    if [ "$(head -c 8 "$cand" 2>/dev/null)" != "ANDROID!" ]; then
        ui_print "    skip: not an Android boot image"; continue
    fi
    csize=$(stat -c%s "$cand")
    if [ "$csize" -gt "$partsize" ]; then
        ui_print "    skip: larger ($csize) than partition ($partsize)"; continue
    fi
    rm -rf "$vdir"; mkdir -p "$vdir"
    if ! (cd "$vdir" && "$MB" unpack "$cand" >/dev/null 2>&1); then
        ui_print "    skip: magiskboot could not unpack it"; continue
    fi
    if [ ! -f "$vdir/kernel" ]; then
        ui_print "    skip: no kernel inside"; continue
    fi
    if ! grep -qF "$BANNER" "$vdir/kernel" 2>/dev/null; then
        ui_print "    skip: kernel is not this DecemberOS build"
        ui_print "    (want: $BANNER)"; continue
    fi
    "$MB" cpio "$vdir/ramdisk.cpio" test >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "1" ]; then
        if [ "$rc" = "0" ]; then
            ui_print "    skip: ramdisk NOT Magisk-patched — flashing it would remove root"
        else
            ui_print "    skip: ramdisk state unsupported (magiskboot cpio test rc=$rc)"
        fi
        continue
    fi
    img="$cand"; imgsize=$csize
    break
done
[ -n "$img" ] || fail "no usable magisk_patched-*.img in /sdcard/Download.
    First patch decemberos-boot.img:
    Magisk app -> Install -> Select and Patch a File.
    (Candidates that were found but rejected are listed above.)"
rm -rf "$vdir"
ui_print "- Selected: $img"
ui_print "- Verified: exact DecemberOS kernel build + Magisk-patched ramdisk"

want=$(sha256sum "$img" | cut -d' ' -f1)

# --- no-op guard ---------------------------------------------------------
cur=$(head -c "$imgsize" "$part" | sha256sum | cut -d' ' -f1)
if [ "$cur" = "$want" ]; then
    ui_print ""
    ui_print "- This exact image is ALREADY on boot$slot — nothing to do."
    abort "NOT AN ERROR — partition already matches; nothing was written"
fi

# --- backup: taken and verified before any write -------------------------
ts=$(date +%Y%m%d-%H%M%S)
bdst=""
for d in /mnt/media_rw/*; do
    [ -d "$d" ] && touch "$d/.dos-wtest" 2>/dev/null && rm -f "$d/.dos-wtest" && bdst="$d" && break
done
[ -n "$bdst" ] || bdst=/sdcard/Download

freek=$(df -Pk "$bdst" 2>/dev/null | awk 'NR==2{print $4}')
needk=$(( partsize / 1024 + 20480 ))
if [ -n "$freek" ] && [ "$freek" -lt "$needk" ]; then
    fail "only ${freek}K free at $bdst — need ${needk}K for the backup"
fi

backup="$bdst/boot${slot}-before-decemberos-$ts.img"
ui_print "- Backing up current boot$slot -> $backup"
dd if="$part" of="$backup" bs=1048576 2>/dev/null || fail "backup dd failed"
sync
psha=$(sha256sum "$part" | cut -d' ' -f1)
bsha=$(sha256sum "$backup" | cut -d' ' -f1)
[ "$psha" = "$bsha" ] || fail "backup does not match the partition (sha mismatch) — refusing to flash without a good backup"
ui_print "- Backup verified (sha256 $bsha)"

# --- dry-run stop ---------------------------------------------------------
if $DRYRUN; then
    ui_print ""
    ui_print "*******************************************"
    ui_print "  DRY RUN COMPLETE — every check passed."
    ui_print "  A verified backup was left at:"
    ui_print "  $backup"
    ui_print "  Nothing was written to $part."
    ui_print "  To flash for real: delete"
    ui_print "  $DRYFLAG"
    ui_print "  and install this zip again."
    ui_print "*******************************************"
    abort "NOT AN ERROR — dry run finished; nothing was flashed"
fi

# --- flash + readback verify ----------------------------------------------
ui_print "- Flashing $img -> boot$slot"
dd if="$img" of="$part" bs=1048576 2>/dev/null || fail "FLASH dd FAILED — do not reboot; flash the restore zip now"
sync

got=$(head -c "$imgsize" "$part" | sha256sum | cut -d' ' -f1)
if [ "$want" != "$got" ]; then
    fail "readback mismatch after flash — do NOT reboot.
    Flash decemberos-kernel-restore.zip now (your verified
    backup is at $backup)."
fi

ui_print ""
ui_print "*******************************************"
ui_print "  DecemberOS kernel flashed and verified."
ui_print "  Verified backup of the old boot:"
ui_print "  $backup"
ui_print "  Reboot now. After boot, uname -a should"
ui_print "  contain: $MARKER"
ui_print "  Undo anytime: decemberos-kernel-restore.zip"
ui_print "*******************************************"
ui_print ""
abort "NOT AN ERROR — flash succeeded; this zip intentionally installs no module"
