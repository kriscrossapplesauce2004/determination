#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
OUT=${TMPDIR:-/tmp}/det-presenter-protocol-test
${CC:-cc} -std=c11 -Wall -Wextra -Wpedantic -Werror \
    -I"$ROOT" "$ROOT/presenter-session.c" \
    "$ROOT/tests/presenter-protocol-test.c" -o "$OUT"
"$OUT"
rm -f "$OUT"
echo "presenter protocol policy tests passed"
