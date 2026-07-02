# DecemberOS Magisk module installer (runs inside Magisk app's install flow).
# Lays down the on-device toolkit under /data/decemberos; the module dir
# itself only carries the boot hooks + sepolicy.

ui_print "- DecemberOS $(grep_prop version "$MODPATH/module.prop")"

DOS=/data/decemberos
mkdir -p "$DOS/bin" "$DOS/log" "$DOS/run" "$DOS/lxc"

for f in evgrab guest-start desktop-on desktop-off cycle-stress.sh; do
    [ -f "$MODPATH/tools/$f" ] || abort "! missing $f in zip"
    cp -f "$MODPATH/tools/$f" "$DOS/bin/$f"
    chmod 0755 "$DOS/bin/$f"
done
cp -f "$MODPATH/tools/lxc-config" "$DOS/lxc/config"

# Keep the payload out of the mounted module dir.
rm -rf "$MODPATH/tools"

# Running the DecemberOS kernel? Warn, don't block — module install before
# kernel flash is a legitimate order of operations.
if [ ! -e /proc/self/ns/pid ] || ! zcat /proc/config.gz 2>/dev/null | grep -q ANDROID_BINDERFS=y; then
    ui_print "! Note: DecemberOS kernel not detected (yet) — guest won't start until it's flashed"
fi

ui_print "- Toolkit installed to $DOS/bin"
ui_print "- Next: push Debian rootfs + static lxc, then $DOS/bin/desktop-on"
