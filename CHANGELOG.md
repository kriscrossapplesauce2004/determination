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

### Known limitations

- Only the OnePlus 7 `guacamoleb` on the tested crDroid 12.11/Android 16 line
  is supported.
- Internal mode freezes `system_server`; Android is not fully live while the
  guest owns the panel.
- Concurrent external DP-alt convergence is not implemented yet.
- The guest hardware/control trust boundary is prototype-grade.
- Several build inputs still follow moving upstream branches; Aqua cannot ship
  until release inputs are pinned and manifested.

See [RELEASES.md](RELEASES.md) for the complete scope and ship gates.
