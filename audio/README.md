# Direct audio foundation

Determination's product audio path is Linux applications -> PipeWire -> ALSA
PCM/control/compress nodes -> the kernel audio/DSP/codec stack. AudioFlinger,
AAudio, `AudioTrack`, and a companion-app PCM server are explicitly not in that
path.

`det-audio-probe` is the first safety primitive. It is read-only and reports:

- every `/dev/snd` node and its ownership;
- the kernel's `/proc/asound` topology;
- every process with an open descriptor into `/dev/snd`;
- an `hardware_unowned` gate suitable for the audio ownership transaction.

It does not open a PCM, change a mixer control, or stop Android components.
Those operations are unsafe until the device profile identifies the exact HAL
services, complete mixer snapshot, codec route, and restoration order.

`det-audio-owner` is the journalled ownership coordinator. It accepts only an
exact, data-only audio profile; snapshots Android init service state; quiesces
the listed hardware owners; requires the probe's zero-holder proof; and restores
the original service set in reverse order. Mutating commands are dry-run unless
`--apply` is explicit. It never reads or writes PCM samples.

The included guacamoleb profile identifies the verified card and Android owners
but intentionally contains no mixer/PCM route yet. The owner is packaged for
manual qualification and is not called by boot or desktop transitions.

Build all three variants with `./audio/build.sh all`. The Android binary runs on
the host side before and after ownership handoff; the glibc binary runs inside
the guest and exposes the same JSON schema.
