#!/bin/sh
# Determination kernel install/restore driven from the PC over a USB cable ---
# the cable-era sibling of the on-phone action zips, with one safety layer
# the zips cannot have: the pre-flash backup is ALSO pulled to this machine
# (artifacts/backups/), so a copy survives anything that happens to the
# phone's storage.
#
# The one step that stays manual is Magisk-patching determination-boot.img in
# the Magisk app (Install -> Select and Patch a File) --- the app owns the
# patch settings and we do not second-guess them from here.
#
# Usage:
#   usb-install/host-flash.sh check            # every check + verified backup, NO write
#   usb-install/host-flash.sh flash [--reboot] # checks + backup + flash + readback
#   usb-install/host-flash.sh restore [--reboot] # flash the pristine artifact back
#   usb-install/host-flash.sh verify           # after reboot: kernel + config sanity
#
# Checks mirror the install zip: exact-build kernel banner, Magisk-patched
# ramdisk (root survives), boot magic, size fit, battery, free space,
# backup sha-verified against the partition before any write, no-op guard,
# readback verify after. 'check' is the dry-run safe mode.

set -eu
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
export PATH="$REPO/toolchain/usr/bin:$PATH"

ADB="${ADB:-$HOME/platform-tools/adb}"
BOOTIMG="$REPO/boot/determination-boot.img"
PRISTINE="${PRISTINE:-$REPO/artifacts/boot_a-crdroid-12.11.img}"
MARKER="melissa@terra"
DMB=/data/adb/magisk/magiskboot
DWORK=/data/local/tmp/det-hostflash

die() { echo "!!! $*" >&2; exit 1; }
rsh() { "$ADB" shell "su -c \"$*\""; }

cmd="${1:-}"; shift 2>/dev/null || true
REBOOT=false
[ "${1:-}" = "--reboot" ] && REBOOT=true
case "$cmd" in check|flash|restore|verify) ;; *)
    sed -n '/^# Usage:/,/^# 'readback'/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac

command -v "$ADB" >/dev/null || die "adb not found at $ADB (set ADB=)"
"$ADB" get-state >/dev/null 2>&1 || die "no adb device connected"
rsh id | grep -q uid=0 || die "su denied --- flip the Shell toggle in Magisk's Superuser tab"

slot=$("$ADB" shell getprop ro.boot.slot_suffix | tr -d '\r\n')
part=/dev/block/bootdevice/by-name/boot$slot
rsh "test -e $part" || die "boot partition not found at $part"
partsize=$(rsh "blockdev --getsize64 $part" | tr -d '\r\n')
echo "device: slot ${slot:-none}, target $part ($partsize bytes)"

# ---------- verify (post-reboot sanity) ------------------------------------
if [ "$cmd" = verify ]; then
    # /proc/version, not uname -a: toybox uname omits the (builder@host) field
    un=$("$ADB" shell cat /proc/version)
    echo "$un"
    echo "$un" | grep -q "$MARKER" || die "running kernel is NOT the Determination build"
    bad=0
    for opt in PID_NS USER_NS IPC_NS CGROUP_DEVICE CGROUP_PIDS POSIX_MQUEUE \
               VT NF_TABLES CHECKPOINT_RESTORE BINFMT_MISC MACVLAN QCA_CLD_WLAN; do
        if rsh "zcat /proc/config.gz" | grep -q "^CONFIG_$opt=y"; then
            echo "  CONFIG_$opt=y"
        else
            echo "  MISSING: CONFIG_$opt"; bad=1
        fi
    done
    [ "$bad" = 0 ] || die "running config is missing Determination options"
    echo "verify OK: Determination kernel is running with all expected options"
    exit 0
fi

battery() {
    b=$("$ADB" shell dumpsys battery 2>/dev/null | awk '/^ *level:/{print $2; exit}' | tr -d '\r\n ')
    [ -n "$b" ] || b=$(rsh "cat /sys/class/power_supply/battery/capacity" 2>/dev/null | tr -d '\r\n ')
    [ -n "$b" ] || { echo "battery unreadable --- continuing"; return 0; }
    [ "$b" -ge 15 ] 2>/dev/null || die "battery at ${b}% --- charge to at least 15% first"
    echo "battery: ${b}%"
}

# Take + verify a backup of the current boot on the phone, then pull a copy
# here and verify that too. Prints the device path; sets $backup/$hostbackup.
take_backup() {
    tag="$1"
    ts=$(date +%Y%m%d-%H%M%S)
    backup="/sdcard/Download/boot${slot}-before-$tag-$ts.img"
    echo "backup: $part -> $backup"
    rsh "dd if=$part of=$backup bs=1048576 && sync" >/dev/null
    psha=$(rsh "sha256sum $part" | cut -d' ' -f1)
    bsha=$(rsh "sha256sum $backup" | cut -d' ' -f1)
    [ "$psha" = "$bsha" ] || die "on-device backup sha mismatch --- refusing to continue"
    mkdir -p "$REPO/artifacts/backups"
    hostbackup="$REPO/artifacts/backups/${backup##*/}"
    "$ADB" pull "$backup" "$hostbackup" >/dev/null
    hsha=$(sha256sum "$hostbackup" | cut -d' ' -f1)
    [ "$hsha" = "$psha" ] || die "pulled backup sha mismatch --- refusing to continue"
    echo "backup verified on device AND pulled to $hostbackup"
}

flash_and_verify() { # $1 = device path of image to flash, $2 = its sha, $3 = size
    rsh "dd if=$1 of=$part bs=1048576 && sync" >/dev/null || die "FLASH dd FAILED --- do not reboot; run '$0 restore'"
    got=$(rsh "head -c $3 $part | sha256sum" | cut -d' ' -f1)
    [ "$got" = "$2" ] || die "readback mismatch --- do NOT reboot; run '$0 restore'"
    echo "flashed and readback-verified"
}

# ---------- restore ----------------------------------------------------------
if [ "$cmd" = restore ]; then
    [ -f "$PRISTINE" ] || die "pristine image $PRISTINE missing"
    case "${PRISTINE##*/}" in boot${slot}-*) ;; *)
        die "pristine ${PRISTINE##*/} is not a boot${slot} dump but the device is on slot $slot" ;;
    esac
    battery
    want=$(sha256sum "$PRISTINE" | cut -d' ' -f1)
    size=$(stat -c%s "$PRISTINE")
    [ "$size" -le "$partsize" ] || die "pristine image exceeds boot partition"
    head -c 8 "$PRISTINE" | grep -q 'ANDROID!' || die "pristine image has invalid Android boot magic"
    cur=$(rsh "head -c $size $part | sha256sum" | cut -d' ' -f1)
    [ "$cur" != "$want" ] || { echo "partition already holds the pristine image --- nothing to do"; exit 0; }
    rsh "mkdir -p $DWORK"
    "$ADB" push "$PRISTINE" "$DWORK/restore.img" >/dev/null
    got=$(rsh "sha256sum $DWORK/restore.img" | cut -d' ' -f1)
    [ "$got" = "$want" ] || die "pushed image sha mismatch"
    take_backup restore
    flash_and_verify "$DWORK/restore.img" "$want" "$size"
    rsh "rm -rf $DWORK"
    echo "pristine boot$slot restored. previous boot backed up at $backup (and $hostbackup)"
    $REBOOT && "$ADB" reboot
    exit 0
fi

# ---------- check / flash ------------------------------------------------------
[ -f "$BOOTIMG" ] || die "$BOOTIMG missing --- run boot/repack.sh"
command -v magiskboot >/dev/null || die "magiskboot not found (toolchain/usr/bin)"
uw=$(mktemp -d); trap 'rm -rf "$uw"' EXIT
(cd "$uw" && magiskboot unpack "$BOOTIMG" >/dev/null 2>&1)
BANNER=$(strings "$uw/kernel" | grep -m1 '^Linux version ')
[ -n "$BANNER" ] || die "could not extract kernel banner from $BOOTIMG"
echo "pinning build: $BANNER"

battery

img=
for candidate in $("$ADB" shell "ls -t /sdcard/Download/magisk_patched-*.img 2>/dev/null" | tr -d '\r'); do
    echo "checking candidate: $candidate"
    candidate_size=$(rsh "stat -c%s '$candidate'" | tr -d '\r\n') || continue
    [ "$candidate_size" -le "$partsize" ] || { echo "  reject: too large"; continue; }
    rsh "head -c 8 '$candidate'" | grep -q 'ANDROID!' || { echo "  reject: bad boot magic"; continue; }
    rsh "rm -rf $DWORK && mkdir -p $DWORK && cd $DWORK && $DMB unpack '$candidate'" >/dev/null 2>&1 || { echo "  reject: unpack failed"; continue; }
    if ! rsh "grep -qF \\\"$BANNER\\\" $DWORK/kernel"; then
        echo "  reject: wrong Determination kernel"; continue
    fi
    rc=0; rsh "cd $DWORK && $DMB cpio ramdisk.cpio test" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || { echo "  reject: ramdisk is not Magisk-patched (rc=$rc)"; continue; }
    img=$candidate; imgsize=$candidate_size; break
done
rsh "rm -rf $DWORK"
[ -n "$img" ] || die "no valid magisk_patched-*.img in /sdcard/Download --- patch determination-boot.img in the Magisk app first"
echo "candidate accepted: $img"
echo "verified: exact Determination kernel build + Magisk-patched ramdisk"

want=$(rsh "sha256sum $img" | cut -d' ' -f1)
cur=$(rsh "head -c $imgsize $part | sha256sum" | cut -d' ' -f1)
if [ "$cur" = "$want" ]; then
    echo "this exact image is already on boot$slot --- nothing to do"
    exit 0
fi

take_backup determination

if [ "$cmd" = check ]; then
    echo
    echo "CHECK COMPLETE --- every check passed, nothing was flashed."
    echo "Verified backups: $backup (device) and $hostbackup (here)."
    echo "Run '$0 flash' to do it for real."
    exit 0
fi

flash_and_verify "$img" "$want" "$imgsize"
echo
echo "Determination kernel flashed. Backups: $backup (device), $hostbackup (here)."
echo "After reboot run: $0 verify"
$REBOOT && "$ADB" reboot
exit 0
