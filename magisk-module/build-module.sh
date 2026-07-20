#!/bin/sh
# Package the Determination Magisk module zip (install via Magisk app -> Modules
# -> Install from storage; no META-INF needed for app installs).
# Pulls the device evgrab binary and toggle scripts in as payload.

set -eu
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
. "$REPO/release/version.sh"
det_load_version "$REPO/version.properties"

[ -f ../tools/evgrab/evgrab ] || { echo "build evgrab for aarch64 first (tools/evgrab, make CC=aarch64-linux-gnu-gcc)" >&2; exit 1; }
file ../tools/evgrab/evgrab | grep -q aarch64 || { echo "evgrab is not an aarch64 build" >&2; exit 1; }

DETD="../control/build/android-arm64/detd"
DETCTL="../control/build/android-arm64/detctl"
DET_GUEST_AGENT="../control/build/guest-arm64/det-guest-agent"
DET_AUDIO_HOST="../audio/build/android-arm64/det-audio-probe"
DET_AUDIO_GUEST="../audio/build/guest-arm64/det-audio-probe"
DET_AUDIO_OWNER="../audio/build/android-arm64/det-audio-owner"
for binary in "$DETD" "$DETCTL"; do
    [ -f "$binary" ] || {
        echo "build the native control plane first (./control/build.sh android)" >&2
        exit 1
    }
    file "$binary" | grep -q 'ARM aarch64' || {
        echo "$binary is not an Android aarch64 build" >&2
        exit 1
    }
done
[ -f "$DET_GUEST_AGENT" ] || {
    echo "build the Debian guest agent first (./control/build.sh guest)" >&2
    exit 1
}
file "$DET_GUEST_AGENT" | grep -q 'ARM aarch64' || {
    echo "$DET_GUEST_AGENT is not a Linux aarch64 build" >&2
    exit 1
}
for binary in "$DET_AUDIO_HOST" "$DET_AUDIO_GUEST" "$DET_AUDIO_OWNER"; do
    [ -f "$binary" ] || {
        echo "build the direct audio probes first (./audio/build.sh all)" >&2
        exit 1
    }
    file "$binary" | grep -q 'ARM aarch64' || {
        echo "$binary is not an aarch64 build" >&2
        exit 1
    }
done

ZYGISK_64="../zygisk/libs/arm64-v8a/libdetermination.so"
ZYGISK_32="../zygisk/libs/armeabi-v7a/libdetermination.so"
[ -f "$ZYGISK_64" ] || { echo "build the zygisk module first (cd zygisk && ndk-build)" >&2; exit 1; }
[ -f "$ZYGISK_32" ] || { echo "build the zygisk module first (cd zygisk && ndk-build)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp customize.sh post-fs-data.sh service.sh sepolicy.rule "$WORK/"
det_render_version_template module.prop.in "$WORK/module.prop"
mkdir -p "$WORK/tools" "$WORK/guest-tools" "$WORK/zygisk" \
    "$WORK/device-profiles" "$WORK/audio-profiles"
cp ../tools/evgrab/evgrab \
   "$DETD" "$DETCTL" "$DET_AUDIO_HOST" "$DET_AUDIO_OWNER" \
   ../toggle/device-config ../toggle/generate-lxc-config ../toggle/generate-guest-config \
   ../toggle/guest-start ../toggle/desktop-on ../toggle/desktop-off \
   ../toggle/run-transition \
   ../toggle/native-plasma ../toggle/native-kms-gate ../toggle/native-restore \
   ../toggle/det-hostagent ../toggle/cycle-stress.sh "$WORK/tools/"
cp ../device-profiles/*.conf "$WORK/device-profiles/"
cp ../audio/profiles/*.conf "$WORK/audio-profiles/"
cp "$DET_GUEST_AGENT" "$WORK/guest-tools/det-guest-agent"
cp "$DET_AUDIO_GUEST" "$WORK/guest-tools/det-audio-probe"
cp ../guest/lxc/config "$WORK/tools/lxc-config-base"
cp "$ZYGISK_64" "$WORK/zygisk/arm64-v8a.so"
cp "$ZYGISK_32" "$WORK/zygisk/armeabi-v7a.so"

OUT="$PWD/determination-magisk-v$DET_VERSION.zip"
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
