#!/usr/bin/env bash
# Upload and execute one approved guest provisioning script through LXC.
set -euo pipefail
case "${1:-}" in
  controls) script=setup-controls.sh ;;
  polish) script=setup-polish.sh ;;
  trim) script=setup-trim.sh ;;
  *) echo "usage: $0 controls|polish|trim" >&2; exit 2 ;;
esac
adb_bin=${ADB:-adb}
guest_root=/data/determination/guest
remote=/sdcard/Download/determination-"$script"
guest_script=/root/"$script"
"$adb_bin" get-state >/dev/null
"$adb_bin" push "guest/$script" "$remote"
"$adb_bin" shell "su -c 'cp "$remote" "$guest_root$guest_script" && chmod 0755 "$guest_root$guest_script"'"
"$adb_bin" shell "su -c '/data/determination/lxc/bin/lxc-attach -P /data/determination -n guest -- "$guest_script"'"
