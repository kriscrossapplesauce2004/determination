#!/system/bin/sh
# These .ko files only load into the DecemberOS kernel build. If the phone is
# booted on any other kernel (e.g. after flashing the restore zip), overlaying
# them would break WLAN the opposite way — so skip the magic mount entirely.
# post-fs-data.sh runs before module mounting, so skip_mount here takes
# effect for this same boot.

MODDIR=${0%/*}
case "$(uname -r)" in
*g96adfa8256dc*) rm -f "$MODDIR/skip_mount" ;;
*) touch "$MODDIR/skip_mount" ;;
esac
