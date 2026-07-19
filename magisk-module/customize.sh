# Determination Magisk module installer (runs inside Magisk app's install flow).
# Lays down the on-device toolkit under /data/determination; the module dir
# itself only carries the boot hooks + sepolicy.

ui_print "- $(grep_prop name "$MODPATH/module.prop") $(grep_prop version "$MODPATH/module.prop")"

DET=/data/determination
mkdir -p "$DET/bin" "$DET/etc" "$DET/log" "$DET/run" "$DET/lxc"

for f in evgrab device-config generate-lxc-config generate-guest-config guest-start desktop-on desktop-off native-plasma native-kms-gate native-restore det-hostagent cycle-stress.sh; do
    [ -f "$MODPATH/tools/$f" ] || abort "! missing $f in zip"
    cp -f "$MODPATH/tools/$f" "$DET/bin/$f"
    chmod 0755 "$DET/bin/$f"
done
cp -f "$MODPATH/tools/lxc-config-base" "$DET/lxc/config.base"

# Install a known profile only on a matching device. Unknown devices use the
# runtime discovery defaults and receive no silently-wrong vendor assumptions.
DEVICE=$(getprop ro.product.device)
[ ! -f "$DET/etc/device.conf" ] && [ -f "$MODPATH/device-profiles/$DEVICE.conf" ] && {
    cp -f "$MODPATH/device-profiles/$DEVICE.conf" "$DET/etc/device.conf"
    chmod 0644 "$DET/etc/device.conf"
    ui_print "- Device profile: $DEVICE"
}
[ -f "$DET/etc/device.conf" ] && ui_print "- Config: $DET/etc/device.conf"

# Keep the payload out of the mounted module dir.
rm -rf "$MODPATH/tools" "$MODPATH/device-profiles"

# Running the Determination kernel? Warn, don't block — module install before
# kernel flash is a legitimate order of operations.
if [ ! -e /proc/self/ns/pid ] || ! zcat /proc/config.gz 2>/dev/null | grep -q ANDROID_BINDERFS=y; then
    ui_print "! Note: Determination kernel not detected (yet) — guest won't start until it's flashed"
elif ! zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_VT=y'; then
    # Kernel #3 marker: VT is off in stock and in kernels #1/#2.
    ui_print "! Note: pre-#3 Determination kernel — VT / nftables / IPv6-NAT need a kernel update"
fi

ui_print "- Toolkit installed to $DET/bin"
ui_print "- Next: push Debian rootfs + static lxc, then $DET/bin/desktop-on"
