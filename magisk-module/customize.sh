# Determination Magisk module installer (runs inside Magisk app's install flow).
# Lays down the on-device toolkit under /data/determination; the module dir
# itself only carries the boot hooks + sepolicy.

ui_print "- $(grep_prop name "$MODPATH/module.prop") $(grep_prop version "$MODPATH/module.prop")"

DET=/data/determination
VERSION=$(grep_prop versionCode "$MODPATH/module.prop")
SETS="$DET/versions"
STAGE="$SETS/.stage-$VERSION-$$"
TARGET="$SETS/$VERSION"
mkdir -p "$STAGE/bin" "$STAGE/guest-tools" "$DET/etc" "$DET/log" "$DET/run" "$DET/lxc" "$SETS"
trap 'rm -rf "$STAGE"' EXIT
[ ! -e "$TARGET" ] || abort "! payload version $VERSION is already staged"

for f in evgrab detd detctl det-audio-probe det-audio-owner device-config generate-lxc-config generate-guest-config lifecycle-lib boot-profile guest-start desktop-on desktop-off run-transition external-presenter native-plasma native-kms-gate native-restore det-hostagent det-color-compat cycle-stress.sh; do
    [ -f "$MODPATH/tools/$f" ] || abort "! missing $f in zip"
    cp -f "$MODPATH/tools/$f" "$STAGE/bin/$f"
    chmod 0755 "$STAGE/bin/$f"
done
cp -f "$MODPATH/tools/lxc-config-base" "$STAGE/lxc-config-base"
for f in det-guest-agent det-audio-probe det-audio-session; do
  if [ -f "$MODPATH/guest-tools/$f" ]; then
    cp -f "$MODPATH/guest-tools/$f" "$STAGE/guest-tools/$f"
    chmod 0755 "$STAGE/guest-tools/$f"
    if [ -d "$DET/guest/usr/local/bin" ]; then
        cp -f "$MODPATH/guest-tools/$f" "$DET/guest/usr/local/bin/$f"
        chmod 0755 "$DET/guest/usr/local/bin/$f"
    fi
  fi
done

# Verify the complete staged set before one atomic pointer change. Keep the
# prior target intact for recovery; runtime paths resolve through current/.
(cd "$STAGE" && find . -type f -print | LC_ALL=C sort | xargs sha256sum) > "$STAGE/SHA256SUMS" || abort "! payload hash generation failed"
printf '%s\n' "$VERSION" > "$STAGE/manifest-id"
mv "$STAGE" "$TARGET" || abort "! payload activation staging failed"
ln -s "versions/$VERSION" "$DET/current.new" || abort "! cannot prepare current payload pointer"
mv -f "$DET/current.new" "$DET/current" || abort "! cannot activate payload pointer"
if [ -d "$DET/bin" ] && [ ! -L "$DET/bin" ]; then
    mv "$DET/bin" "$SETS/legacy-bin" || abort "! cannot preserve prior toolkit"
fi
ln -s current/bin "$DET/bin.new" && mv -f "$DET/bin.new" "$DET/bin" || abort "! cannot activate toolkit"
if [ -d "$DET/guest-tools" ] && [ ! -L "$DET/guest-tools" ]; then
    mv "$DET/guest-tools" "$SETS/legacy-guest-tools" || abort "! cannot preserve guest tools"
fi
ln -s current/guest-tools "$DET/guest-tools.new" && mv -f "$DET/guest-tools.new" "$DET/guest-tools" || abort "! cannot activate guest tools"
if [ -e "$DET/lxc/config.base" ] && [ ! -L "$DET/lxc/config.base" ]; then
    cp -f "$DET/lxc/config.base" "$SETS/legacy-lxc-config-base" || abort "! cannot preserve LXC base"
    rm -f "$DET/lxc/config.base"
fi
ln -s ../current/lxc-config-base "$DET/lxc/config.base.new" && mv -f "$DET/lxc/config.base.new" "$DET/lxc/config.base" || abort "! cannot activate LXC base"

# Install a known profile only on a matching device. Unknown devices use the
# runtime discovery defaults and receive no silently-wrong vendor assumptions.
DEVICE=$(getprop ro.product.device)
[ ! -f "$DET/etc/device.conf" ] && [ -f "$MODPATH/device-profiles/$DEVICE.conf" ] && {
    cp -f "$MODPATH/device-profiles/$DEVICE.conf" "$DET/etc/device.conf"
    chmod 0644 "$DET/etc/device.conf"
    ui_print "- Device profile: $DEVICE"
}
# Merge newly introduced typed capabilities into an existing exact-match
# profile without replacing locally qualified values.
if [ -f "$DET/etc/device.conf" ] && [ -f "$MODPATH/device-profiles/$DEVICE.conf" ]; then
    for key in DET_LINUX_FIRST_SUPPORTED DET_LINUX_FIRST_KEEP_NETWORK DET_LINUX_FIRST_FREEZE_SYSTEM_SERVER; do
        grep -q "^$key=" "$DET/etc/device.conf" && continue
        value=$(sed -n "s/^$key=//p" "$MODPATH/device-profiles/$DEVICE.conf" | head -n 1)
        [ -z "$value" ] || printf '%s=%s\n' "$key" "$value" >> "$DET/etc/device.conf"
    done
fi
[ -f "$DET/etc/device.conf" ] && ui_print "- Config: $DET/etc/device.conf"

# Audio ownership profiles are stricter than general device discovery: never
# guess service names or codec topology. Install only the exact hardware profile
# selected by the exact-match device config, and preserve local qualification.
AUDIO_PROFILE_ID=$(sed -n 's/^DET_PROFILE_ID=//p' "$DET/etc/device.conf" 2>/dev/null | head -n 1)
if [ -n "$AUDIO_PROFILE_ID" ] && \
   [ -f "$MODPATH/audio-profiles/$AUDIO_PROFILE_ID.conf" ] && \
   [ ! -f "$DET/etc/audio-owner.conf" ]; then
    cp -f "$MODPATH/audio-profiles/$AUDIO_PROFILE_ID.conf" "$DET/etc/audio-owner.conf"
    chmod 0640 "$DET/etc/audio-owner.conf"
    ui_print "- Direct audio ownership profile: $AUDIO_PROFILE_ID (manual gate only)"
fi

# Keep the payload out of the mounted module dir.
rm -rf "$MODPATH/tools" "$MODPATH/guest-tools" "$MODPATH/device-profiles" \
    "$MODPATH/audio-profiles"

# Running the Determination kernel? Warn, don't block --- module install before
# kernel flash is a legitimate order of operations.
if [ ! -e /proc/self/ns/pid ] || ! zcat /proc/config.gz 2>/dev/null | grep -q ANDROID_BINDERFS=y; then
    ui_print "! Note: Determination kernel not detected (yet) --- guest won't start until it's flashed"
elif ! zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_VT=y'; then
    # Kernel #3 marker: VT is off in stock and in kernels #1/#2.
    ui_print "! Note: pre-#3 Determination kernel --- VT / nftables / IPv6-NAT need a kernel update"
fi

ui_print "- Toolkit installed to $DET/bin"
ui_print "- Next: push Debian rootfs + static lxc, then $DET/bin/desktop-on"
