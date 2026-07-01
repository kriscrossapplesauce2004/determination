#!/bin/sh
# Fetch the downstream kernel source for guacamoleb.
#
# The phone runs crDroid 12.10 / Android 16 (artifacts/rom-identity.txt) with
# kernel 4.14.357-openela — so we rebuild from crDroid's sm8150 fork to stay
# ABI/feature-identical to what the ROM ships, and only layer the container
# fragment on top. Verify the branch matches the installed build; fall back to
# LineageOS lineage-23 tree if crDroid's fork is stale.

set -eu
cd "$(dirname "$0")"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/crdroidandroid/android_kernel_oneplus_sm8150.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-16.0}"

if [ -d src/.git ]; then
    echo "kernel/src already present; git -C src pull to update"
    exit 0
fi

git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" src
echo "Fetched $KERNEL_REPO ($KERNEL_BRANCH) into kernel/src"
