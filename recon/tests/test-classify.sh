#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_case() {
    NAME=$1
    WANT=$2
    python3 recon/classify.py "recon/tests/fixtures/$NAME" "$TMP/$NAME" >/dev/null
    grep -Fx "DET_CAP_STATUS=$WANT" "$TMP/$NAME/capabilities.conf" >/dev/null
}

run_case hidl-ready bringup-ready
run_case aidl-blocked blocked
run_case missing-evidence blocked

echo "recon classifier fixtures passed"
