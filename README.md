# DecemberOS

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

## Repo layout

| Path | What |
|---|---|
| `recon/` | §9 device recon — run first, with the phone attached |
| `kernel/` | kconfig fragment (container enables) + fetch/build scripts for the downstream SM8150 kernel |
| `boot/` | boot.img unpack/repack with the custom kernel; Magisk patching flow |
| `magisk-module/` | the on-device DecemberOS Magisk module: container launch, boot hooks, sepolicy rules |
| `guest/` | Debian arm64 rootfs builder + LXC config (binder/kgsl/dmabuf `/dev`, `/vendor`, property area bind-mounts, libhybris) |
| `toggle/` | §4 internal-panel handoff: SF stop + respawn suppression + compositor swap + input grab |
| `tools/evgrab/` | small C daemon that holds `EVIOCGRAB` on evdev nodes during desktop mode |
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
- [ ] Recon run on real device (needs USB)
- [ ] Kernel built + boot.img flashed
- [ ] libhybris smoke test on guacamoleb
- [ ] Toggle stable across repeated cycles
