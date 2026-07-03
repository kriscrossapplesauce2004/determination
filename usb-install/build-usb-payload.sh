#!/bin/sh
# Build the two Magisk "action zips" (kernel install / kernel restore) and
# stage the complete USB-drive payload into dist/usb-payload/. Copy that
# folder to the drive (or `./dos publish` pushes it over adb) and the whole
# install is doable on the phone alone: patch, flash zip, reboot.

set -eu
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
DIST="$REPO/dist"
PAYLOAD="$DIST/usb-payload"

BOOTIMG="$REPO/boot/decemberos-boot.img"
# Pristine dump of the boot slot the phone is currently on (override via env
# after an OTA moves slots/versions). Slot is derived from the filename and
# baked into the restore zip's slot guard.
PRISTINE="${PRISTINE:-$REPO/artifacts/boot_a-crdroid-12.11.img}"
MODZIP=$(ls "$REPO"/magisk-module/decemberos-magisk-v*.zip 2>/dev/null | sort -V | tail -n1)

[ -f "$BOOTIMG" ] || { echo "missing $BOOTIMG — run boot/repack.sh" >&2; exit 1; }
[ -f "$PRISTINE" ] || { echo "missing pristine boot dump $PRISTINE" >&2; exit 1; }
[ -n "$MODZIP" ] || { echo "missing module zip — run magisk-module/build-module.sh" >&2; exit 1; }
case "${PRISTINE##*/}" in
    boot_a-*) SLOT=_a ;;
    boot_b-*) SLOT=_b ;;
    *) echo "cannot derive slot from pristine filename ${PRISTINE##*/} (want boot_a-*/boot_b-*)" >&2; exit 1 ;;
esac

mkzip() { # mkzip <outzip> <dir-with-files> [extra: name=path ...]
    python3 - "$@" <<'EOF'
import os, sys, zipfile
out, srcdir, *extra = sys.argv[1:]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(srcdir):
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, srcdir))
    for e in extra:
        name, path = e.split('=', 1)
        z.write(path, name)
EOF
}

rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"

# --- install zip: scripts only, tiny -----------------------------------
mkzip "$PAYLOAD/decemberos-kernel-install.zip" install
echo "built decemberos-kernel-install.zip"

# --- restore zip: embeds the pristine boot image, checksum baked in ----
SHA=$(sha256sum "$PRISTINE" | cut -d' ' -f1)
SIZE=$(stat -c%s "$PRISTINE")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
sed -e "s/@SHA256@/$SHA/" -e "s/@SIZE@/$SIZE/" -e "s/@SLOT@/$SLOT/" restore/customize.sh > "$WORK/customize.sh"
cp restore/module.prop "$WORK/"
mkzip "$PAYLOAD/decemberos-kernel-restore.zip" "$WORK" "boot.img=$PRISTINE"
echo "built decemberos-kernel-restore.zip (embeds pristine boot$SLOT ${PRISTINE##*/}, sha256 $SHA)"

# --- the rest of the drive ---------------------------------------------
cp "$BOOTIMG" "$PAYLOAD/decemberos-boot.img"
cp "$MODZIP" "$PAYLOAD/"
cp README.md "$PAYLOAD/README-INSTALL.md" 2>/dev/null || true

sha256sum "$PAYLOAD"/* | sed "s|$PAYLOAD/||" > "$PAYLOAD/SHA256SUMS"
echo
echo "USB payload staged in dist/usb-payload/:"
ls -la "$PAYLOAD"
