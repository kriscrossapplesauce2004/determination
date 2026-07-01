#!/bin/sh
# Fetch the downstream kernel source for guacamoleb.
#
# Primary: LineageOS msm-4.14 tree for sm8150 — actively maintained, known to
# boot on OnePlus 7 series, and closer to buildable-with-modern-clang than the
# OnePlusOSS dump. Override KERNEL_REPO/KERNEL_BRANCH to use OnePlusOSS
# (android_kernel_oneplus_sm8150, oneplus/SM8150_R_11.0) instead.

set -eu
cd "$(dirname "$0")"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_oneplus_sm8150.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-22.2}"

if [ -d src/.git ]; then
    echo "kernel/src already present; git -C src pull to update"
    exit 0
fi

git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" src
echo "Fetched $KERNEL_REPO ($KERNEL_BRANCH) into kernel/src"
