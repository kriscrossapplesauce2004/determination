#!/bin/sh
# Package the Determination Magisk module zip (install via Magisk app -> Modules
# -> Install from storage; no META-INF needed for app installs).
# Pulls the device evgrab binary and toggle scripts in as payload.

set -eu
cd "$(dirname "$0")"

[ -f ../tools/evgrab/evgrab ] || { echo "build evgrab for aarch64 first (tools/evgrab, make CC=aarch64-linux-gnu-gcc)" >&2; exit 1; }
file ../tools/evgrab/evgrab | grep -q aarch64 || { echo "evgrab is not an aarch64 build" >&2; exit 1; }

ZYGISK_64="../zygisk/libs/arm64-v8a/libdetermination.so"
ZYGISK_32="../zygisk/libs/armeabi-v7a/libdetermination.so"
[ -f "$ZYGISK_64" ] || { echo "build the zygisk module first (cd zygisk && ndk-build)" >&2; exit 1; }
[ -f "$ZYGISK_32" ] || { echo "build the zygisk module first (cd zygisk && ndk-build)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp module.prop customize.sh post-fs-data.sh service.sh sepolicy.rule "$WORK/"
mkdir -p "$WORK/tools" "$WORK/zygisk"
cp ../tools/evgrab/evgrab \
   ../toggle/guest-start ../toggle/desktop-on ../toggle/desktop-off \
   ../toggle/det-hostagent ../toggle/cycle-stress.sh "$WORK/tools/"
cp ../guest/lxc/config "$WORK/tools/lxc-config"
cp "$ZYGISK_64" "$WORK/zygisk/arm64-v8a.so"
cp "$ZYGISK_32" "$WORK/zygisk/armeabi-v7a.so"

VER=$(sed -n 's/^version=//p' module.prop)
OUT="$PWD/determination-magisk-$VER.zip"
rm -f "$OUT"
# python zipfile: no zip(1) dependency, deterministic enough for our use
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
