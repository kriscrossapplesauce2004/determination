/*
 * Retired Android AAudio experiment.
 *
 * Determination product audio is PipeWire -> ALSA -> kernel/DSP/codec. Keeping
 * an AAudio transport buildable makes it far too easy to accidentally regress
 * to an Android framework dependency, so this source intentionally fails.
 * See audio/ and docs/audio-architecture.md.
 */
#error "det-audiobridge is retired; use the direct audio stack in audio/"
