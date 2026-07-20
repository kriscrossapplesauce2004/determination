#!/bin/sh
set -eu

OWNER=$1
PROBE=$2
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/det/bin" "$FIXTURE/det/etc" "$FIXTURE/root/proc/asound" \
    "$FIXTURE/root/proc/sys/kernel/random" "$FIXTURE/root/dev/snd" \
    "$FIXTURE/services"
cp "$PROBE" "$FIXTURE/det/bin/det-audio-probe"
printf ' 0 [Tavil]: msm - sm8150-tavil-snd-card\n' > "$FIXTURE/root/proc/asound/cards"
printf 'fixture-boot-id\n' > "$FIXTURE/root/proc/sys/kernel/random/boot_id"
printf 'running\n' > "$FIXTURE/services/audioserver"
printf 'running\n' > "$FIXTURE/services/vendor.audio-hal"
printf '%s\n' \
    'schema=1' \
    'profile=guacamoleb' \
    'card_contains=sm8150-tavil-snd-card' \
    'service=audioserver' \
    'service=vendor.audio-hal' \
    'timeout_ms=1000' > "$FIXTURE/det/etc/audio-owner.conf"

printf '%s\n' \
    '#!/bin/sh' \
    'name=${1#init.svc.}' \
    'cat "'"$FIXTURE"'/services/$name"' > "$FIXTURE/getprop"
printf '%s\n' \
    '#!/bin/sh' \
    'verb=${1#ctl.}' \
    'name=$2' \
    'case "$verb" in stop) state=stopped ;; start) state=running ;; *) exit 2 ;; esac' \
    'printf "%s\\n" "$state" > "'"$FIXTURE"'/services/$name"' > "$FIXTURE/setprop"
chmod +x "$FIXTURE/getprop" "$FIXTURE/setprop"

COMMON="--root $FIXTURE/det --profile $FIXTURE/det/etc/audio-owner.conf --probe $FIXTURE/det/bin/det-audio-probe --probe-root $FIXTURE/root --getprop $FIXTURE/getprop --setprop $FIXTURE/setprop"
# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
$OWNER claim $COMMON | grep -q '"apply":false'
grep -q running "$FIXTURE/services/audioserver"

# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
$OWNER claim --apply $COMMON | grep -q 'hardware claimed'
grep -q stopped "$FIXTURE/services/audioserver"
grep -q stopped "$FIXTURE/services/vendor.audio-hal"
test -f "$FIXTURE/det/run/control/audio-claimed"
# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
$OWNER status --root "$FIXTURE/det" | grep -q '"phase":"claimed"'

# A post-claim guest holder must block Android restoration until it releases.
mkdir -p "$FIXTURE/root/proc/77/fd"
printf 'guest-pipewire\n' > "$FIXTURE/root/proc/77/comm"
printf 'guest-pipewire\000' > "$FIXTURE/root/proc/77/cmdline"
ln -s /dev/snd/pcmC0D0p "$FIXTURE/root/proc/77/fd/9"
if $OWNER restore --apply $COMMON >/dev/null 2>&1; then
    echo "audio owner restored Android while guest still held ALSA" >&2
    exit 1
fi
grep -q stopped "$FIXTURE/services/audioserver"
test ! -e "$FIXTURE/det/run/control/audio-claimed"
rm -f "$FIXTURE/root/proc/77/fd/9"
# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
$OWNER recover --apply $COMMON | grep -q 'ownership restored'

# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
grep -q running "$FIXTURE/services/audioserver"
grep -q running "$FIXTURE/services/vendor.audio-hal"
# shellcheck disable=SC2086 -- fixture paths contain no whitespace.
$OWNER status --root "$FIXTURE/det" | grep -q '"phase":"restored"'

# A surviving /dev/snd holder must abort the claim and restore both services.
printf 'still-owning-audio\n' > "$FIXTURE/root/proc/77/comm"
printf 'still-owning-audio\000' > "$FIXTURE/root/proc/77/cmdline"
ln -s /dev/snd/pcmC0D0p "$FIXTURE/root/proc/77/fd/9"
if $OWNER claim --apply $COMMON >/dev/null 2>&1; then
    echo "audio owner accepted hardware with a live ALSA holder" >&2
    exit 1
fi
grep -q running "$FIXTURE/services/audioserver"
grep -q running "$FIXTURE/services/vendor.audio-hal"
$OWNER status --root "$FIXTURE/det" | grep -q '"phase":"rolled-back"'
