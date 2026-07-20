# Determination control plane

This directory contains the host-side bionic control-plane foundation:

- `detd`: the single state/API owner;
- `detctl`: the reference CLI and protocol client;
- `libdetcontrol`: versioned protocol, durable state, system probes and the
  bounded fixed-argv adapter runner.

The first deployment starts `detd` in observe-only mode. Mutating mode requests
are rejected until transition ownership and device recovery tests pass. The
existing `desktop-on`, `desktop-off`, and `guest-start` scripts remain the
proven transition implementation during migration.

Build and test on the host, then cross-build for Android arm64:

```sh
./control/build.sh host
./control/build.sh android
```

For an isolated host smoke test:

```sh
root=$(mktemp -d)
mkdir -p "$root/run" "$root/state"
./control/build/host/detd --root "$root" --foreground &
./control/build/host/detctl --root "$root" doctor --json
```

Protocol and state details are documented in
[`docs/platform-overhaul.md`](../docs/platform-overhaul.md).

