#!/bin/sh
# Build the guacamoleb kernel with the DecemberOS container fragment merged in.
#
# Base config: the RUNNING kernel's /proc/config.gz (artifacts/
# kernel-config-full.txt from recon) — guaranteed parity with what crDroid
# ships, rather than reconstructing their defconfig+fragment recipe. The only
# delta is decemberos.config.
#
# Toolchain: distro clang (tree has the ACK LLVM= backport) + GNU aarch64
# binutils in ../toolchain/usr/bin (extracted Arch pkg, no root needed).
#
# Output: out/arch/arm64/boot/Image.gz-dtb for boot/repack.sh. dtbo is NOT
# rebuilt — the ROM's flashed dtbo pairs fine with a same-source kernel.

set -eu
cd "$(dirname "$0")"

BASECONFIG="${BASECONFIG:-../artifacts/kernel-config-full.txt}"
JOBS="${JOBS:-$(nproc)}"
export PATH="$PWD/../toolchain/usr/bin:$PATH"

[ -d src ] || { echo "run kernel/fetch.sh first" >&2; exit 1; }
[ -f "$BASECONFIG" ] || { echo "base config $BASECONFIG missing (recon artifact)" >&2; exit 1; }
command -v aarch64-linux-gnu-as >/dev/null || { echo "aarch64 binutils not found" >&2; exit 1; }

KMAKE="make -C src O=$PWD/out ARCH=arm64 CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-"

mkdir -p out
cp "$BASECONFIG" out/.config
# Merge the container-enable fragment on top of the running kernel's config.
(cd src && KCONFIG_CONFIG="$PWD/../out/.config" scripts/kconfig/merge_config.sh -O "$PWD/../out" -m "$PWD/../out/.config" "$PWD/../decemberos.config")
$KMAKE olddefconfig

# Verify the merge actually took — a silently-dropped option here costs a
# flash-and-boot cycle to discover.
for opt in NAMESPACES USER_NS PID_NS IPC_NS NET_NS CGROUP_DEVICE CGROUP_PIDS POSIX_MQUEUE ANDROID_BINDERFS VETH OVERLAY_FS; do
    grep -q "^CONFIG_$opt=y" out/.config || { echo "MERGE FAILED: CONFIG_$opt not set" >&2; exit 1; }
done
echo "config OK: all DecemberOS options present"

time $KMAKE -j"$JOBS" Image.gz-dtb

echo
echo "Kernel: out/arch/arm64/boot/Image.gz-dtb"
echo "Next: boot/repack.sh"
