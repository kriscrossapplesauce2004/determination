# Build and package

Status: current host-side guide
Authority: build and release maintainers
Last reviewed: 2026-07-30

## Scope

This guide identifies entrypoints. It does not authorize flashing or device
mutation. Read [install and recovery](install-and-recovery.md) before a device
qualification run.

## Host prerequisites

Use a Linux host with Git, Python 3, the Android SDK and NDK versions recorded
in the release manifest, official Android platform tools, and the component
toolchains described by their build scripts. Build inputs must be pinned for a
release; development branches are not release inputs.

## Entry points

| Component | Entry point | Output and gate |
|---|---|---|
| Recon | `recon/recon.sh --serial SERIAL` | reviewed report and capability classification |
| Kernel | `kernel/fetch.sh`, then `kernel/build.sh` | configuration and image candidate |
| Boot packaging | `boot/repack.sh` | validated boot-image candidate |
| Companion | Gradle wrapper in `companion/` | debug or signed release APK |
| Module and USB payload | `magisk-module/build-module.sh`, `usb-install/build-usb-payload.sh` | versioned archive and checksums |
| Release audit | `release/check.sh check` | static development checks |

Do not treat a successful build as a supported device result. Record the commit,
release manifest, profile digest, tool versions, and output hashes before any
hardware qualification.
