#!/bin/sh
# Build the two Magisk "action zips" (kernel install / kernel restore) and
# stage the complete USB-drive payload into dist/usb-payload/. Copy that
# folder to the drive (or `./det publish` pushes it over adb) and the whole
# install is doable on the phone alone: patch, flash zip, reboot.

set -eu
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
DIST="$REPO/dist"
PAYLOAD="$DIST/usb-payload"
. "$REPO/release/version.sh"
det_load_version "$REPO/version.properties"

BOOTIMG="$REPO/boot/determination-boot.img"
# Pristine dump of the boot slot the phone is currently on (override via env
# after an OTA moves slots/versions). Slot is derived from the filename and
# baked into the restore zip's slot guard.
PRISTINE="${PRISTINE:-$REPO/artifacts/boot_a-crdroid-12.11.img}"
MODZIP="$REPO/magisk-module/determination-magisk-v$DET_VERSION.zip"
COMPANION_APK="$REPO/companion/app/build/outputs/apk/release/app-release.apk"

[ -f "$BOOTIMG" ] || { echo "missing $BOOTIMG --- run boot/repack.sh" >&2; exit 1; }
[ -f "$PRISTINE" ] || { echo "missing pristine boot dump $PRISTINE" >&2; exit 1; }
[ -f "$MODZIP" ] || { echo "missing $MODZIP --- run magisk-module/build-module.sh" >&2; exit 1; }
[ -f "$COMPANION_APK" ] || { echo "missing release APK --- build companion:release first" >&2; exit 1; }
case "${PRISTINE##*/}" in
    boot_a-*) SLOT=_a ;;
    boot_b-*) SLOT=_b ;;
    *) echo "cannot derive slot from pristine filename ${PRISTINE##*/} (want boot_a-*/boot_b-*)" >&2; exit 1 ;;
esac

mkzip() { # mkzip <outzip> <dir-with-files> [extra: name=path ...]
    python3 - "$@" <<'EOF'
import os, stat, sys, time, zipfile
out, srcdir, *extra = sys.argv[1:]
epoch = max(315532800, int(os.environ.get('SOURCE_DATE_EPOCH', '315532800')))
stamp = time.gmtime(epoch)[:6]
files = [(os.path.relpath(os.path.join(root, f), srcdir), os.path.join(root, f))
         for root, _, names in os.walk(srcdir) for f in names]
files += [tuple(e.split('=', 1)) for e in extra]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name, path in sorted(files):
        info = zipfile.ZipInfo(name, stamp)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (stat.S_IFREG | 0o644) << 16
        with open(path, 'rb') as src:
            z.writestr(info, src.read(), compress_type=zipfile.ZIP_DEFLATED,
                       compresslevel=9)
EOF
}

rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- install zip: scripts only, tiny -----------------------------------
# Bake the FULL version banner of the kernel inside determination-boot.img
# into the install zip --- its identity check then pins this exact build
# (including build timestamp), so a stale magisk_patched image from an
# older build is rejected on the phone instead of discovered at boot.
export PATH="$REPO/toolchain/usr/bin:$PATH"
command -v magiskboot >/dev/null || { echo "magiskboot not found (toolchain/usr/bin)" >&2; exit 1; }
mkdir -p "$WORK/unpack"
(cd "$WORK/unpack" && magiskboot unpack "$BOOTIMG" >/dev/null 2>&1)
BANNER=$(strings "$WORK/unpack/kernel" | grep -m1 '^Linux version ')
[ -n "$BANNER" ] || { echo "could not extract kernel banner from $BOOTIMG" >&2; exit 1; }
case "$BANNER" in *[\|\&]*) echo "banner contains sed-unsafe chars: $BANNER" >&2; exit 1 ;; esac

mkdir -p "$WORK/install"
sed "s|@BANNER@|$BANNER|" install/customize.sh > "$WORK/install/customize.sh"
det_render_version_template install/module.prop.in "$WORK/install/module.prop"
mkzip "$PAYLOAD/determination-kernel-install.zip" "$WORK/install"
echo "built determination-kernel-install.zip (pins: $BANNER)"

# --- restore zip: embeds the pristine boot image, checksum baked in ----
SHA=$(sha256sum "$PRISTINE" | cut -d' ' -f1)
SIZE=$(stat -c%s "$PRISTINE")
mkdir -p "$WORK/restore"
sed -e "s/@SHA256@/$SHA/" -e "s/@SIZE@/$SIZE/" -e "s/@SLOT@/$SLOT/" restore/customize.sh > "$WORK/restore/customize.sh"
det_render_version_template restore/module.prop.in "$WORK/restore/module.prop"
mkzip "$PAYLOAD/determination-kernel-restore.zip" "$WORK/restore" "boot.img=$PRISTINE"
echo "built determination-kernel-restore.zip (embeds pristine boot$SLOT ${PRISTINE##*/}, sha256 $SHA)"

# --- the rest of the drive ---------------------------------------------
cp "$BOOTIMG" "$PAYLOAD/determination-boot.img"
cp "$MODZIP" "$PAYLOAD/"
cp "$COMPANION_APK" "$PAYLOAD/determination-companion-v$DET_VERSION.apk"
cp README.md "$PAYLOAD/README-INSTALL.md" 2>/dev/null || true

sha256sum "$PAYLOAD"/* | sed "s|$PAYLOAD/||" > "$PAYLOAD/SHA256SUMS"
echo
echo "USB payload staged in dist/usb-payload/:"
ls -la "$PAYLOAD"
