#!/bin/sh
# Build the Debian arm64 guest rootfs on the host, then push to the device.
# Needs: mmdebstrap (preferred) or debootstrap + qemu-user-static binfmt.
#
# libhybris and the wlroots hwcomposer backend come from the Droidian repos —
# their wlroots<->hwcomposer plumbing IS milestones 1-2 of this project (spec
# §10); we consume it, we don't rewrite it.
#
# Usage: guest/build-rootfs.sh [suite]   (default: trixie)

set -eu
cd "$(dirname "$0")"

SUITE="${1:-trixie}"
OUT=rootfs.tar.gz

if command -v mmdebstrap >/dev/null; then
    BOOTSTRAP=mmdebstrap
elif command -v debootstrap >/dev/null; then
    echo "note: debootstrap path needs qemu-user-static binfmt for arm64" >&2
    BOOTSTRAP=debootstrap
else
    echo "error: install mmdebstrap (preferred) or debootstrap" >&2
    exit 1
fi

PKGS="systemd-sysv,dbus,sudo,udev,libinput-tools,seatd,wayland-protocols"
# Compositor + hybris stack; sway is the first wlroots target (spec §3).
PKGS="$PKGS,sway,foot,wmenu"

if [ "$BOOTSTRAP" = mmdebstrap ]; then
    mmdebstrap --architectures=arm64 \
        --include="$PKGS" \
        --customize-hook='./customize-hook.sh "$1"' \
        "$SUITE" "$OUT" \
        http://deb.debian.org/debian
else
    WORK=$(mktemp -d)
    debootstrap --arch=arm64 --include="$(echo "$PKGS" | tr , ' ')" "$SUITE" "$WORK" http://deb.debian.org/debian
    ./customize-hook.sh "$WORK"
    tar -C "$WORK" -czf "$OUT" .
    rm -rf "$WORK"
fi

echo "Rootfs: guest/$OUT"
echo "Push:   adb push $OUT /data/determination/ && adb shell su -c 'mkdir -p /data/determination/guest && tar -xzf /data/determination/$OUT -C /data/determination/guest'"
