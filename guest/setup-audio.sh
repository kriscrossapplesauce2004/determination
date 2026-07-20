#!/bin/sh
# Install the guest half of the direct ALSA/PipeWire path. Safe to rerun.
set -eu

[ "$(id -u)" = 0 ] || { echo "run setup-audio.sh as guest root" >&2; exit 1; }
MODE=${1:-install}
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ "$MODE" != "--configure-only" ]; then
    apt-get update
    apt-get install -y pipewire pipewire-pulse wireplumber alsa-utils
fi

install -d /etc/pipewire/pipewire.conf.d /usr/local/bin
if [ -f "$HERE/det-audio-session" ]; then
    install -m 0755 "$HERE/det-audio-session" /usr/local/bin/det-audio-session
fi

cat > /etc/pipewire/pipewire.conf.d/90-determination-direct.conf <<'EOF'
# Direct phone hardware runs at the Qualcomm stack's native 48 kHz. These are
# bounded starting values, not a latency claim; on-device xruns decide tuning.
context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum       = 256
    default.clock.min-quantum   = 128
    default.clock.max-quantum   = 1024
}
EOF

cat > /etc/profile.d/determination-audio.sh <<'EOF'
# Clients may negotiate larger buffers; this requests a bounded 5.3 ms quantum.
export PIPEWIRE_LATENCY=256/48000
EOF

echo "direct PipeWire configuration installed"
echo "it remains dormant until det-audio-owner publishes audio-claimed"
