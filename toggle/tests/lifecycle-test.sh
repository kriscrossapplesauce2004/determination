#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/etc" "$WORK/lxc" "$WORK/host/dev"
ln -s "$ROOT/toggle/device-config" "$WORK/bin/device-config"
ln -s "$ROOT/toggle/lifecycle-lib" "$WORK/bin/lifecycle-lib"
ln -s "$ROOT/toggle/boot-profile" "$WORK/bin/boot-profile"
cp "$ROOT/toggle/tests/profile-fixtures/valid.conf" "$WORK/etc/device.conf"
touch "$WORK/host/dev/example-gpu"

DET="$WORK" DET_HOST_ROOT="$WORK/host" sh "$ROOT/toggle/generate-lxc-config" \
    "$ROOT/guest/lxc/config" "$WORK/lxc/config"
grep -q '^lxc.mount.entry = /dev/example-gpu ' "$WORK/lxc/config"
grep -q '^/dev/example-gpu$' "$WORK/lxc/device-manifest"

cp "$ROOT/toggle/tests/profile-fixtures/invalid-injection.conf" "$WORK/etc/device.conf"
if DET="$WORK" sh -c '. "$DET/bin/device-config"'; then
    echo "expected injected profile rejection" >&2; exit 1
fi
[ ! -e /tmp/should-not-exist ]
cp "$ROOT/toggle/tests/profile-fixtures/invalid-key.conf" "$WORK/etc/device.conf"
if DET="$WORK" sh -c '. "$DET/bin/device-config"'; then
    echo "expected unknown key rejection" >&2; exit 1
fi

# Boot profile has a structured detctl handshake. A failed apply must return
# to PHONE after one automatic attempt rather than retrying at every boot.
cat > "$WORK/bin/detctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DET/detctl.calls"
exit "${DETCTL_RC:-0}"
EOF
chmod 0755 "$WORK/bin/detctl"
cat > "$WORK/bin/guest-start" <<'EOF'
#!/bin/sh
echo guest-start >> "$DET/lifecycle.calls"
EOF
cat > "$WORK/bin/desktop-on" <<'EOF'
#!/bin/sh
echo desktop-on >> "$DET/lifecycle.calls"
EOF
cat > "$WORK/bin/desktop-off" <<'EOF'
#!/bin/sh
echo "desktop-off $*" >> "$DET/lifecycle.calls"
EOF
chmod 0755 "$WORK/bin/guest-start" "$WORK/bin/desktop-on" "$WORK/bin/desktop-off"
DET="$WORK" sh "$ROOT/toggle/boot-profile" linux-first
grep -q '^desired=linux-first$' "$WORK/state/boot-profile"
DET="$WORK" DETCTL_RC=4 sh "$ROOT/toggle/boot-profile" apply
grep -q '^result=committed$' "$WORK/state/boot-profile"
grep -q '^guest-start$' "$WORK/lifecycle.calls"
grep -q '^desktop-on$' "$WORK/lifecycle.calls"
before=$(wc -l < "$WORK/lifecycle.calls")
if DET="$WORK" DETCTL_RC=9 sh "$ROOT/toggle/boot-profile" apply; then
    echo "expected protocol mismatch failure" >&2; exit 1
fi
[ "$(wc -l < "$WORK/lifecycle.calls")" -eq "$before" ]
DET="$WORK" sh "$ROOT/toggle/boot-profile" failed
grep -q '^desired=phone$' "$WORK/state/boot-profile"
grep -q '^attempt_count=1$' "$WORK/state/boot-profile"
grep -q '^result=recovery-required$' "$WORK/state/boot-profile"
grep -q '^boot-profile linux-first$' "$WORK/detctl.calls"
grep -q '^boot-apply --wait --deadline 45$' "$WORK/detctl.calls"

if DET="$WORK" sh "$ROOT/toggle/desktop-off" unexpected; then
    echo "expected desktop-off argument rejection" >&2; exit 1
fi

# Legacy guest files retain only the safe exit route; power requires RPC.
grep -q 'denied legacy power command' "$ROOT/toggle/det-hostagent"
grep -q 'idle_wait.*120' "$ROOT/toggle/det-hostagent"
echo "lifecycle profile fixtures: PASS"
