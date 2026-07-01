#!/bin/sh
# Repack boot.img with the DecemberOS kernel, keeping the stock ramdisk.
# Magisk then patches the *ramdisk* of the result on-device (or via the app's
# "Select and Patch a File") — kernel swap and ramdisk patch are independent
# layers by design (spec §2), so we never touch the ramdisk here.
#
# Usage: boot/repack.sh <stock-boot.img> [kernel-image]
# Needs: magiskboot on PATH (extract from a Magisk apk: lib/x86_64/libmagiskboot.so)

set -eu
cd "$(dirname "$0")"

STOCK="${1:?usage: repack.sh <stock-boot.img> [kernel]}"
KERNEL="${2:-../kernel/out/arch/arm64/boot/Image.gz-dtb}"

command -v magiskboot >/dev/null || {
    echo "magiskboot not on PATH. Get it: download Magisk apk," >&2
    echo "unzip lib/x86_64/libmagiskboot.so -> magiskboot, chmod +x." >&2
    exit 1
}
[ -f "$KERNEL" ] || { echo "kernel image $KERNEL not found (run kernel/build.sh)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$STOCK" "$WORK/boot.img"
cp "$KERNEL" "$WORK/kernel-new"

cd "$WORK"
magiskboot unpack boot.img
mv kernel-new kernel
magiskboot repack boot.img
cd - >/dev/null

cp "$WORK/new-boot.img" decemberos-boot.img
echo "Wrote boot/decemberos-boot.img"
echo
echo "Next:"
echo "  1. Patch with Magisk app (Select and Patch a File) -> magisk_patched.img"
echo "  2. First boot WITHOUT flashing:  fastboot boot magisk_patched.img"
echo "     Only 'fastboot flash boot' after it survives a boot + recon check."
