#!/bin/bash
# Push + run guest/setup-controls.sh inside the container (mirror of
# run_polish.sh). Run in PHONE mode; no network needed.
set -e
G=/data/determination
echo "Pushing..."
adb push guest/setup-controls.sh /sdcard/Download/setup-controls.sh
echo "Copying to tmp..."
adb shell "su -c 'cp /sdcard/Download/setup-controls.sh $G/guest/rootfs/tmp/setup-controls.sh'"
echo "Copying to root and making executable..."
adb shell "su -c '$G/lxc/bin/lxc-attach -P $G -n guest -- /bin/cp /tmp/setup-controls.sh /root/setup-controls.sh'"
adb shell "su -c '$G/lxc/bin/lxc-attach -P $G -n guest -- /bin/chmod +x /root/setup-controls.sh'"
echo "Executing setup-controls.sh..."
adb shell "su -c '$G/lxc/bin/lxc-attach -P $G -n guest -- /root/setup-controls.sh'"
echo "Done."
