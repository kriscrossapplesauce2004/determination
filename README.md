# Determination

Android convergence layer for Android 16

Android stays PID1; a glibc Wayland desktop runs as an LXC guest
on the **same downstream vendor kernel**; `libhybris` bridges the guest to the
bionic GPU/display blobs. Shipped as a custom `boot.img` (custom kernel +
Magisk-patched ramdisk) plus a Zygisk module : **not a ROM**. `/system` and
`/vendor` stay stock.

Two modes:

- **External convergence** (concurrent): SurfaceFlinger keeps the internal
  panel, the guest compositor drives a DP-alt external display. Both live.
- **Internal on-demand desktop*: SF is stopped and
  respawn-masked, the guest compositor takes the panel via hwcomposer, input is
  handed off with `EVIOCGRAB`.





## Repo layout

| Path | What |
|---|---|
| `recon/` | §9 device recon : run first, with the phone attached |
| `kernel/` | kconfig fragment (container enables) + fetch/build scripts for the downstream SM8150 kernel |
| `boot/` | boot.img unpack/repack with the custom kernel; Magisk patching flow |
| `magisk-module/` | the on-device Determination Magisk module: container launch, boot hooks, sepolicy rules |
| `guest/` | Debian arm64 rootfs builder + LXC config (binder/kgsl/dmabuf `/dev`, `/vendor`, property area bind-mounts, libhybris) |
| `toggle/` | §4 internal-panel handoff: SF stop + respawn suppression + compositor swap + input grab; plus `det-hostagent`  |
| `control/` | native `detd` state/API owner, `detctl` client, durable-state/protocol core, and host tests |
| `audio/` | direct ALSA hardware inventory and journalled ownership binaries |
| `companion/` | Android UI and permission facade: mode confirmation, status/API, Quick Settings, share sheet, optional external presenter |
| `tools/evgrab/` | small C daemon that holds `EVIOCGRAB` on evdev nodes during desktop mode |
| `usb-install/` | cable-free install: Magisk action zips that flash/restore the kernel from a USB drive on the phone itself |
| `zygisk/` | Zygisk/LSPosed module for `system_server` hooks |
| `docs/` | Current wiki: guides, architecture, reference, operations, qualification, and separated history |

## Host validation

Run every host-safe check from the repository root:

```sh
./tools/check-host.sh
```



## Linux-first profile

Supported device profiles can request a health-gated Linux-first startup while
retaining the minimum Android and vendor services needed for the downstream
kernel, radio, thermal, power, binder, and qualified networking stack:

```sh
det linux-first status
det linux-first enable
det linux-first apply
det linux-first disable
```

A failed automatic attempt returns to phone mode and disables automatic retry
until it is explicitly enabled again. See the
[boot-profile reference](docs/reference/device-and-boot-profiles.md) and
[recovery guide](docs/guides/install-and-recovery.md) before enabling it.

## Bring-up order (risk-ordered milestones)



## Guest SSH

The guest SSH server is public-key-only. The host routes the private guest
subnet through the phone's current Wi-Fi address, giving the container a real
directly reachable address:

```sh
det ssh-setup                    # server, public key, SSH config, host route
ssh melissa@192.168.117.2        # exactly this; no ProxyCommand
det ssh-route                    # refresh after phone DHCP or host route changes
det motd-setup                   # refresh the guest's dynamic login banner
```

Pass an existing public key to `det ssh-setup` if preferred. Set
its matching private key in `~/.ssh/config.d/determination` when it is not the
default dedicated `~/.ssh/determination_ed25519` key.
