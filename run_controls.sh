#!/bin/bash
# Push + run guest/setup-controls.sh inside the container. Run in PHONE mode;
# no network needed. Drops the script straight into the guest's /root (on the
# persistent rootfs, NOT /tmp which can be a tmpfs) then lxc-attach runs it.
set -e
G=/data/determination
echo "Pushing..."
adb push guest/setup-controls.sh /sdcard/Download/setup-controls.sh
echo "Placing in guest /root..."
adb shell "su -c 'cp /sdcard/Download/setup-controls.sh $G/guest/root/setup-controls.sh && chmod +x $G/guest/root/setup-controls.sh'"
echo "Executing setup-controls.sh in guest..."
adb shell "su -c '$G/lxc/bin/lxc-attach -P $G -n guest -- /root/setup-controls.sh'"
echo "Done."
