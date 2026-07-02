#!/bin/sh
# Package the DecemberOS kernel-modules overlay zip. Overlays
# /vendor/lib/modules via magic mount; /vendor on disk stays untouched.
# The wlan module is shipped under both its build name (wlan.ko) and the
# name OnePlus vendor init actually insmods (qca_cld3_wlan.ko).

set -eu
cd "$(dirname "$0")"

WLAN=../kernel/out/drivers/staging/qcacld-3.0/wlan.ko
[ -f "$WLAN" ] || { echo "build kernel modules first (make ... modules)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp module.prop customize.sh post-fs-data.sh "$WORK/"
MODS="$WORK/system/vendor/lib/modules"
mkdir -p "$MODS"
cp "$WLAN" "$MODS/wlan.ko"
cp "$WLAN" "$MODS/qca_cld3_wlan.ko"
# any other modules the build produced, minus duplicates of wlan
find ../kernel/out -name '*.ko' ! -path '*qcacld*' -exec cp {} "$MODS/" \;

VER=$(sed -n 's/^version=//p' module.prop)
OUT="$PWD/decemberos-kmods-$VER.zip"
rm -f "$OUT"
(cd "$WORK" && python3 -c "
import os, zipfile
with zipfile.ZipFile('$OUT', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('.'):
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, '.'))
")
echo "Wrote ${OUT##*/}"
python3 -c "import zipfile; print('\n'.join(zipfile.ZipFile('$OUT').namelist()))"
