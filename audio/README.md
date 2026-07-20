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

Build all three variants with `./audio/build.sh all`. The Android binary runs on
the host side before and after ownership handoff; the glibc binary runs inside
the guest and exposes the same JSON schema.
