# Direct audio architecture

Status: foundation implemented; hardware routing not yet qualified on-device.

## Product invariant

Determination audio is a Linux hardware stack:

```text
Linux application
  -> PipeWire / pipewire-pulse
  -> ALSA PCM and control API
  -> Qualcomm ASoC + DSP + Tavil codec kernel drivers
  -> speaker, headset, microphone, USB or DP
```

AudioFlinger, AAudio, `AudioTrack`, the Android audio Binder APIs, and the
companion app never carry Determination PCM. They are not fallbacks. During an
exclusive internal-codec handoff Android's owners must be quiesced, but they do
not become a transport or service dependency.

The guest owns the application graph. A small host component may arbitrate
hardware ownership and execute a device-profile route transaction, but it must
never proxy sample buffers.

## Current foundation

`det-audio-probe` has Android/bionic and Debian/glibc builds with one stable
JSON schema. It inventories `/dev/snd`, captures `/proc/asound`, identifies all
open ALSA descriptors, and implements a read-only `--require-unowned` gate.
The same binary on each side makes namespace and permission mismatches obvious.

The Android binary is packaged as `/data/determination/bin/det-audio-probe`.
The guest binary is installed as `/usr/local/bin/det-audio-probe` on each guest
start. Neither binary opens a PCM or mutates a mixer.

## Ownership transaction

Internal display mode needs an exclusive codec transaction. This becomes a
journalled `detd` child operation, not another free-running shell loop:

1. Refuse the request during calls, alarms, recording, or an existing audio
   transition unless the policy explicitly permits interruption.
2. Record the device profile, kernel boot ID, service states, every relevant
   ALSA control value, active route, node ownership, and current `/dev/snd`
   holders to an fsync'd journal.
3. Quiesce the profile's Android audio owners in dependency order. This is
   arbitration only; no Android audio API is used.
4. Run `det-audio-probe --require-unowned`. Any remaining holder aborts and
   restores the journal.
5. Apply the exact profile route and permissions, then expose the nodes to the
   guest. Unknown controls, cards, or topology hashes are a hard failure.
6. Start the guest PipeWire graph and prove a bounded PCM stream. Record hw/appl
   pointers, negotiated format/rate/periods, xruns, and startup latency.
7. On exit, stop the graph, verify the guest released every node, restore mixer
   controls in reverse order, then restart only Android owners which were
   running in the snapshot.
8. Verify Android can reopen the card. Keep the journal if verification fails
   and surface recovery through `detctl doctor`; never silently declare success.

Daemon death recovery reads the journal phase. Pre-claim phases roll back;
post-claim phases first terminate the bounded guest graph, then restore. The
emergency recovery command is fixed and cannot accept arbitrary service names
or mixer controls from an app client.

## Route model

Routes are data selected by an exact device profile, with topology hashes to
prevent applying OnePlus 7 mixer values to a vaguely similar phone. Each route
describes:

- card identity and required PCM/control/compress nodes;
- playback/capture PCM, format, rate, period and buffer bounds;
- complete precondition and postcondition controls;
- ordered enable and reverse-disable operations;
- speaker amplifier/DSP dependencies and safe gain ceilings;
- jack detection, DP/HDMI ELD, USB hotplug, and microphone privacy policy;
- Android owner stop/start order and timeout;
- a reversible verification action.

UCM2 is preferred where it can fully express a route. A tiny native adapter is
allowed for Qualcomm-specific topology or amplifier sequencing, but only mixer
and route metadata cross that boundary—never PCM buffers.

## Concurrency policy

Internal phone codec ownership is exclusive until the driver stack proves safe
sharing. External convergence can stay concurrent by choosing independent
hardware: DP/HDMI ALSA, USB Audio Class, or a Bluetooth backend managed directly
from Linux. If a route is not independently ownable, capabilities report it as
unavailable; Determination does not smuggle it through Android.

## Qualification gate

Direct audio is not called working until all of these pass on-device:

- exact card/PCM/control inventory captured on both sides;
- zero `/dev/snd` holders after quiesce;
- a direct speaker tone with a conservative gain ceiling;
- Android route and service state restored byte-for-byte;
- PipeWire app playback without a companion service;
- volume/mute, headset and DP/USB routes;
- suspend/wake, cable cycles, daemon kill, guest crash and failed-restore tests;
- measured latency, drift and xrun recovery under CPU/GPU load;
- microphone disabled by default with visible privacy state when enabled.

Until those gates pass, the honest state is `direct_audio=inventory`, not
`audio=working`.
