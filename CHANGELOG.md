# Changelog

This file tracks project-wide releases. Component-level version numbers may be
different and are recorded in the release manifest.

## 0.5.0 "Aqua" - in development

### Added

- One project-wide version/codename source consumed by every installable
  artifact, replacing the unrelated bring-up-era component versions.
- Internal phone-to-desktop handoff with SurfaceFlinger release, exclusive
  input transfer, and restoration to Android.
- Non-root Debian desktop session with Phosh and companion/QS controls.
- Stable desktop-mode networking through the `system_server` freezer path.
- Native Turnip/KGSL + minigbm graphics path, raw KMS scanout, and Plasma
  Mobile under KWin with GPU compositing and touch.
- Compatibility-first graphics policy: vendor EGL/GLES through libhybris,
  Android-gralloc buffer ownership, and minigbm as the compositor GBM layer.
- A display-safe gralloc/vendor-EGL/minigbm shared-buffer interoperability
  probe, passed on guacamoleb, with the native Mesa launcher guarded as an
  explicit experiment.
- A reproducible offscreen compatibility benchmark with frame-time percentiles,
  full native-handle setup cost, and minigbm import/export timing.
- Runtime device discovery and exact-match device-profile foundations.
- Verified boot-image install, backup, restore, and dry-run paths.
- Native `detd`/`detctl` control plane with framed authenticated RPC, durable
  state, bounded adapters, journalled transitions, rollback and restart
  reconciliation; boot remains observe-only pending device qualification.
- Native guest agent and capability-scoped guest endpoint, replacing the file
  channel for health and phone-mode exit while retaining the old path as a
  migration fallback.
- Permissioned Android app API: explicit read-only status/capability/metrics
  intents, user-confirmed mode requests, and a signature-protected AIDL facade.
- Independent external-display presenter with full native-handle/fence protocol,
  peer authentication, resource quotas, mode-change handling and teardown-safe
  SurfaceControl references.
- Direct-audio foundation: Android/guest ALSA topology and holder probes,
  journalled hardware-owner arbitration, exact-match guacamoleb profile,
  guest PipeWire claim gating and zero-holder restore checks.
- Unified native doctor/metrics snapshots spanning transition, guest, direct
  audio, presenter, pressure, memory and process health.

### Changed

- Companion audio no longer uses or packages `AudioTrack`, AAudio, AudioFlinger,
  a PCM TCP bridge, media-playback foreground-service policy, or Internet
  permission. Product PCM is PipeWire to ALSA hardware.
- Status and guest health collect all named process states in one `/proc` pass
  instead of rescanning the process tree for every service.
- External presentation has its own lifecycle and no longer depends on audio.

### Fixed

- Removed the desktop transition's forced Android Night Light colour-
  temperature snapshot/pulse, including the stale forced 4000 K device state.
- Same-display external mode changes now rebuild the presentation instead of
  being ignored because the display ID did not change.

### Known limitations

- Only the OnePlus 7 `guacamoleb` on the tested crDroid 12.11/Android 16 line
  is supported.
- Internal mode freezes `system_server`; Android is not fully live while the
  guest owns the panel.
- Concurrent external DP-alt convergence is not implemented yet.
- Direct internal-codec routes and mixer restoration are not yet qualified on
  hardware; ownership remains explicit/manual and no sound claim is made.
- The guest hardware/control trust boundary is prototype-grade.
- Several build inputs still follow moving upstream branches; Aqua cannot ship
  until release inputs are pinned and manifested.

See [RELEASES.md](RELEASES.md) for the complete scope and ship gates.
