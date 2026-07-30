#!/bin/sh
# Build static aarch64 LXC tools for the Android host side and (optionally)
# push them to the phone. Produces the /data/determination/lxc/bin toolset that
# guest-start / desktop-on / desktop-off exec.
#
# Toolchain: the repo's toolchain/usr/bin cross gcc + static glibc (same
# Arch aarch64-linux-gnu packages as the kernel build). LXC 4.0 LTS because
# autotools + glibc static is a proven combo; 5.x/meson wants musl for
# static builds.
#
# Everything optional is disabled: the guest is a privileged container
# launched by root --- isolation is not the threat model (spec: the container
# exists for the glibc world, not for sandboxing). Fewer libs, fewer
# static-link fights.
#
# gcc >= 14 note: glibc 2.40+ declares mount_setattr itself; LXC 4.0's own
# declaration trips -Wincompatible-pointer-types, an error by default now.
# The structs are layout-identical --- downgrade, don't patch (same policy as
# the kernel's KCFLAGS -Wno- rule in AGENTS.md).
#
# Usage: guest/build-lxc.sh [--push]

set -eu
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
export PATH="$REPO/toolchain/usr/bin:$PATH"

LXCVER=4.0.12
WORK="${WORK:-$REPO/dist/lxc-build}"
OUT="$REPO/dist/lxc-bin"
ADB="${ADB:-$HOME/platform-tools/adb}"
TOOLS="lxc-start lxc-stop lxc-attach lxc-info lxc-ls lxc-console lxc-execute"

command -v aarch64-linux-gnu-gcc >/dev/null || { echo "cross gcc missing (toolchain/)" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
[ -d "lxc-$LXCVER" ] || {
    curl -fsSLO "https://linuxcontainers.org/downloads/lxc/lxc-$LXCVER.tar.gz"
    tar xzf "lxc-$LXCVER.tar.gz"
}
cd "lxc-$LXCVER"

[ -f Makefile ] || ./configure --host=aarch64-linux-gnu \
    --prefix=/data/determination/lxc \
    --with-config-path=/data/determination \
    --with-runtime-path=/data/determination/run \
    --disable-shared --enable-static \
    --disable-capabilities --disable-seccomp --disable-apparmor \
    --disable-selinux --disable-openssl --disable-doc --disable-api-docs \
    --disable-examples --disable-tests --disable-pam --disable-memfd-rexec \
    CC=aarch64-linux-gnu-gcc

make -j"$(nproc)" LDFLAGS="-all-static" \
    CFLAGS="-g -O2 -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration"

mkdir -p "$OUT"
for t in $TOOLS; do
    cp -f "src/lxc/$t" "$OUT/"
    file "$OUT/$t" | grep -q "aarch64.*statically linked" || { echo "$t is not a static aarch64 binary" >&2; exit 1; }
done
echo "Static LXC tools staged in $OUT"

if [ "${1:-}" = "--push" ]; then
    "$ADB" shell "mkdir -p /data/local/tmp/lxcbin"
    for t in $TOOLS; do "$ADB" push "$OUT/$t" /data/local/tmp/lxcbin/; done
    "$ADB" shell "su -c 'mkdir -p /data/determination/lxc/bin && cp -f /data/local/tmp/lxcbin/* /data/determination/lxc/bin/ && chmod 755 /data/determination/lxc/bin/* && rm -rf /data/local/tmp/lxcbin && /data/determination/lxc/bin/lxc-start --version'"
fi
