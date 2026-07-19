# Determination

Android convergence layer for the OnePlus 7 (`guacamoleb`, SM8150 / Adreno 640).

Android stays PID1 and fully live; a glibc Wayland desktop runs as an LXC guest
on the **same downstream vendor kernel**; `libhybris` bridges the guest to the
bionic GPU/display blobs. Shipped as a custom `boot.img` (custom kernel +
Magisk-patched ramdisk) plus a Zygisk module — **not a ROM**. `/system` and
`/vendor` stay stock.

Two modes:

- **External convergence** (concurrent): SurfaceFlinger keeps the internal
  panel, the guest compositor drives a DP-alt external display. Both live.
- **Internal on-demand desktop** (time-sliced): SF is stopped and
  respawn-masked, the guest compositor takes the panel via hwcomposer, input is
  handed off with `EVIOCGRAB`. Toggle back restores the phone.

Full rationale, topology decision, and risk register: see
[`docs/design-spec.md`](docs/design-spec.md).

Current project release train: **Determination 0.5 "Aqua"** (in development).
The Deltarune-character naming scheme, release scope, and actual ship gates are
in [`RELEASES.md`](RELEASES.md); project-wide changes are in
[`CHANGELOG.md`](CHANGELOG.md).

## Repo layout

| Path | What |
|---|---|
| `recon/` | §9 device recon — run first, with the phone attached |
| `kernel/` | kconfig fragment (container enables) + fetch/build scripts for the downstream SM8150 kernel |
| `boot/` | boot.img unpack/repack with the custom kernel; Magisk patching flow |
| `magisk-module/` | the on-device Determination Magisk module: container launch, boot hooks, sepolicy rules |
| `guest/` | Debian arm64 rootfs builder + LXC config (binder/kgsl/dmabuf `/dev`, `/vendor`, property area bind-mounts, libhybris) |
| `toggle/` | §4 internal-panel handoff: SF stop + respawn suppression + compositor swap + input grab; plus `det-hostagent` (guest→host control channel) |
| `companion/` | native Android app: enter desktop mode + live status + Quick Settings tile (phone-side control) |
| `tools/evgrab/` | small C daemon that holds `EVIOCGRAB` on evdev nodes during desktop mode |
| `usb-install/` | cable-free install: Magisk action zips that flash/restore the kernel from a USB drive on the phone itself |
| `zygisk/` | Zygisk/LSPosed module for `system_server` hooks (desktop-mode flags, summon UX) — milestone 6 |
| `docs/` | design spec, bring-up notes |

## Bring-up order (risk-ordered milestones)

1. **Recon** — `recon/recon.sh` with the device on USB. Determines composer HAL
   flavour (HIDL 2.x vs AIDL composer3) and gralloc/mapper version, which gates
   the libhybris backend choice.
2. **Kernel** — `kernel/fetch.sh && kernel/build.sh`, then `boot/repack.sh` and
   Magisk-patch the result. Flash to a *non-active slot / with a way back*.
3. **Guest** — `guest/build-rootfs.sh` on the host, push, register with the
   on-device LXC from the Magisk module. libhybris EGL smoke test
   (`test_hwcomposer`) must pass before anything else.
4. **wlroots on the panel**, then **the toggle** (`toggle/`), cycle-stressed.
5. External convergence, KWin, summon UX — in that order.

## Status

- [x] Repo scaffolding, recon script, kernel fragment, Magisk module, guest
      builder, toggle scripts, evgrab
- [x] Recon on real device over wireless adb → `docs/recon-findings.md`
      (crDroid 12.10/A16, HIDL composer 2.4, gralloc4, binderfs present,
      DP-alt works)
- [x] Kernel built (crDroid 16.0 tree + running config + fragment, 3m13s),
      `boot/determination-boot.img` repacked from the dumped boot_b and verified
- [x] Module zip packaged with static aarch64 evgrab; `./det` host helper
- [x] Cable-free install path: `usb-install/` action zips + `./det publish`
      (flash via Magisk app + `dd`; rescue from a *bootloop* still needs a cable)
- [x] **FLASHED AND BOOTING** (2026-07-02, via the USB-drive path): kernel
      `4.14.357-perf-g96adfa8256dc` live on device, PID/USER/IPC_NS confirmed.
      WiFi initially exposed a `qca_cld3_wlan.ko` vermagic mismatch; the current
      kernel build carries the matching module directly, so the old Magisk WLAN
      overlay has been retired. Full hardware smoke test green. Determination
      module installed. Milestone 1 done.
- [x] Guest rootfs + libhybris smoke test on guacamoleb (2026-07-04, TLS wall
      cleared with upstream libhybris; `test_hwcomposer` GLES 3.2 on the panel)
- [x] wlroots on the panel: phoc + phosh + squeekboard live, touch-verified
      (2026-07-06/07); GPU app buffers zero-copy path working (2026-07-10)
- [x] Toggle round trip cable-free: companion app Enter, guest launchers /
      phosh power menu Exit, verified on-device (2026-07-11) — milestone 4 done
      (QS tile confirmed)
- [x] Milestone 6: Zygisk hook on system_server's SF-death handling —
      verified on device 2026-07-11: system_server stable, WiFi stays up,
      guest networking alive throughout desktop mode
- [x] Milestone 5 phase 1: native graphics/KMS path proven (2026-07-13/14) —
      Turnip on KGSL, minigbm allocation, dmabuf→Vulkan import, raw DSI KMS
      scanout, and Plasma Mobile under KWin with GPU compositing + touch.
      This is retained as an explicit native-Mesa experiment, not the portable
      product renderer.
- [ ] Compatibility KWin path: vendor EGL/GLES through libhybris, Android
      gralloc allocation, and minigbm as the compositor-facing GBM layer. The
      first shared-buffer interop gate passed on-device (2026-07-19): vendor
      Adreno rendered through a reconstructed full native handle, pixel readback
      through the original allocation matched, and minigbm imported/re-exported
      its pixel dma-buf. The display-safe 1080x2340 benchmark completes four
      fullscreen textured/blended layers in 4.263 ms mean / 4.625 ms p99;
      full-handle and minigbm setup cost 8 us and 92 us mean respectively.
      Direct KWin integration, authoritative plane metadata, presentation, and
      sync-fence transport remain.
- [ ] Milestone 5 phase 2: concurrent external convergence — Android/SF keeps
      the panel while a guest-rendered dmabuf is presented on DP-alt
