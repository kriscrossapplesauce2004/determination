#!/bin/sh
set -eu

PROBE=$1
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/dev/snd" "$FIXTURE/proc/asound" "$FIXTURE/proc/42/fd"
touch "$FIXTURE/dev/snd/controlC0" "$FIXTURE/dev/snd/pcmC0D0p"
printf ' 0 [Tavil ]: msm - sm8150-tavil-snd-card\n' > "$FIXTURE/proc/asound/cards"
printf 'audiod\n' > "$FIXTURE/proc/42/comm"
printf 'audiod\000--direct\000' > "$FIXTURE/proc/42/cmdline"
ln -s /dev/snd/pcmC0D0p "$FIXTURE/proc/42/fd/7"

json=$($PROBE --root "$FIXTURE")
printf '%s\n' "$json" | grep -q '"node_count":2'
printf '%s\n' "$json" | grep -q '"holder_count":1'
printf '%s\n' "$json" | grep -q '"comm":"audiod"'
printf '%s\n' "$json" | grep -q 'sm8150-tavil-snd-card'

if "$PROBE" --root "$FIXTURE" --require-unowned >/dev/null 2>&1; then
    echo "require-unowned accepted a live ALSA holder" >&2
    exit 1
else
    [ "$?" -eq 3 ]
fi
