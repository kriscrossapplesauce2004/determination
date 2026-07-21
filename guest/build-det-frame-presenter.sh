#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SRC=${1:-/root/det-frame-presenter.c}
CLIENT=${2:-/root/presenter-client.c}
HEADERS=${3:-/root/determination-graphics}
OUT=${4:-/usr/local/bin/det-frame-presenter}

cc -std=c11 -O2 -Wall -Wextra -Werror \
    -I/usr/local/include -I"$HEADERS" \
    "$SRC" "$CLIENT" -o "$OUT" \
    -L/usr/local/lib -Wl,-rpath,/usr/local/lib \
    -lEGL -lhybris-common

