#!/bin/bash
set -e
echo "Pushing..."
adb push guest/setup-polish.sh /sdcard/Download/setup-polish.sh
echo "Copying to tmp..."
adb shell "su -c 'cp /sdcard/Download/setup-polish.sh /data/decemberos/guest/rootfs/tmp/setup-polish.sh'"
echo "Copying to root and making executable..."
adb shell "su -c '/data/decemberos/lxc/bin/lxc-attach -P /data/decemberos -n guest -- /bin/cp /tmp/setup-polish.sh /root/setup-polish.sh'"
adb shell "su -c '/data/decemberos/lxc/bin/lxc-attach -P /data/decemberos -n guest -- /bin/chmod +x /root/setup-polish.sh'"
echo "Executing setup-polish.sh..."
adb shell "su -c '/data/decemberos/lxc/bin/lxc-attach -P /data/decemberos -n guest -- /root/setup-polish.sh'"
echo "Done."
