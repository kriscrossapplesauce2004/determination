#!/bin/sh
# Build the guacamoleb kernel with the DecemberOS container fragment merged in.
# Needs: clang (AOSP clang preferred, distro clang usually works for msm-4.14),
# lld, make, flex, bison, openssl headers, and for the DTB/dtbo: mkdtimg
# (from AOSP libufdt, packaged as `mkdtimg`/`mkdtboimg` in most distros).
#
# Output: out/arch/arm64/boot/Image.gz-dtb (+ dtbo.img) for boot/repack.sh.

set -eu
cd "$(dirname "$0")"

[ -d src ] || { echo "run kernel/fetch.sh first" >&2; exit 1; }

DEFCONFIG="${DEFCONFIG:-vendor/sm8150-perf_defconfig}"
JOBS="${JOBS:-$(nproc)}"
export ARCH=arm64
KMAKE="make -C src O=$PWD/out ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-"

# Some trees name it differently; probe.
if [ ! -e "src/arch/arm64/configs/$DEFCONFIG" ]; then
    echo "defconfig $DEFCONFIG not found; candidates:" >&2
    ls src/arch/arm64/configs/ | grep -Ei 'sm8150|guac|oneplus' >&2 || true
    exit 1
fi

$KMAKE "$DEFCONFIG"
# Merge the container-enable fragment on top of the stock defconfig.
KCONFIG_CONFIG=out/.config src/scripts/kconfig/merge_config.sh -O out -m out/.config decemberos.config
$KMAKE olddefconfig

# Verify the merge actually took — a silently-dropped option here costs a
# flash-and-boot cycle to discover.
for opt in NAMESPACES USER_NS PID_NS NET_NS CGROUP_DEVICE VETH OVERLAY_FS; do
    grep -q "^CONFIG_$opt=y" out/.config || { echo "MERGE FAILED: CONFIG_$opt not set" >&2; exit 1; }
done

$KMAKE -j"$JOBS" Image.gz-dtb dtbs

echo
echo "Kernel: out/arch/arm64/boot/Image.gz-dtb"
echo "Next: boot/repack.sh"
