# Determination — project context

Android convergence layer for melissa's OnePlus 7 (`guacamoleb`, SM8150 /
Adreno 640). Android stays PID1; a Debian LXC guest on the same downstream
kernel takes the display via libhybris→hwcomposer. Ships as custom boot.img +
Magisk module + Zygisk — never a ROM, never touches /system.

**Read first:** `docs/design-spec.md` (authoritative design), `docs/recon-findings.md`
(device ground truth), `README.md` (repo map + milestones).

## Device (recon-verified, don't re-derive)

- crDroid 12.11 / Android 16 (SDK 36), slot `_a`. Magisk 30.7 + ReZygisk.
- Kernel `4.14.357-openela` (crDroid sm8150 fork, branch `16.0`).
- Composer: HIDL `graphics.composer@2.1–2.4` (no AIDL). Gralloc: QTI mapper@4.0.
- binderfs in kernel; guest gets private binderfs in its IPC ns.
- DP-alt over USB-C works; Android native desktop mode runs on it.

## Talking to the phone

- USB cable connected (fastboot recovery possible). Wireless adb as fallback
  (official platform-tools only, port rotates per reboot).
- **Never `adb root`**. Root = `adb shell "su -c '<cmds>'"`. If su returns
  permission denied, Shell toggle in Magisk Superuser tab is off.
- Flash path: `usb-install/host-flash.sh check|flash|restore|verify` or Magisk
  action zips. Dry-run: `touch /sdcard/Download/determination-dryrun`.

## Build system

- `kernel/build.sh`: merges `determination.config` onto running kernel config,
  verifies all options, compiles. Toolchain in `toolchain/` (gitignored).
- `boot/repack.sh`: swaps kernel into boot.img via magiskboot (from `toolchain/usr/bin`).
- Zygisk: `cd zygisk && ndk-build NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=jni/Android.mk NDK_APPLICATION_MK=jni/Application.mk`
- Companion: `~/android-sdk/gradle-8.7/bin/gradle --no-daemon assembleDebug` in `companion/`.
- NDK at `~/android-sdk/ndk/27.2.12479018`. Platform-tools at `~/platform-tools`.

## Conventions

- Probe/script outputs → `artifacts/`. Structured recon → `recon/report-*/`.
- Commit as work lands; author `melissa <theonest262@gmail.com>`.
- `~/op7-port/` + pmOS = mainline kernel track. Don't mix with Determination.

## Key technical facts

**Guest compositor stack:** phoc 0.47 (droidian `group/102/keypad-slide-lights`)
on droidian wlroots fork (`feature/next/backport-0.18`), built in-guest against
upstream libhybris. Build script: `guest/build-wlroots-phoc.sh`.

**libhybris:** built from upstream master (has PR #609, A15/16 support).
`guest/build-libhybris.sh`. Includes: GSK struct-varying rewrite hook (Adreno
flat-struct bug), eglSwapBuffersWithDamageKHR override, epoxy EGL_EXT_device_query
filter, HWCNativeWindowSetBufferCount, setDisplayBrightness(1.0) after power-on.

**hwc2-compat:** standalone NDK cross-build, `hwc2-compat/build.sh`. Installs to
guest `/usr/lib/android/`.

**GPU app buffers:** hybris wayland EGL platform (zero-copy). Clients need
`EGL_PLATFORM=wayland HYBRIS_EGLPLATFORM=wayland`. `GSK_RENDERER=ngl`.
`/etc/profile.d/hybris.sh` sets defaults. Gate: `guest/gpu-smoke.sh`.

**Input:** wlroots EVIOCGRAB handoff, libinput udev properties
(`det-input-udevdb`), quirks for touchpanel, seatd needs /dev/tty0-2.

**Non-root session (2026-07-12):** the guest desktop runs as unprivileged
`melissa` (uid 1000), NOT root. `desktop-on` does root-only prep (udev DB, seatd,
create `/run/user/1000`, `chmod a+r /etc/phoc.ini`) then `runuser -u melissa`
launches phoc + phosh; runtime dir is `/run/user/1000`. Device access works
because GPU/dri/binder/ashmem are world-rw and kgsl/ion are 1000-owned (uid
1000 == Android AID_SYSTEM); the ONE gate is `/dev/input/*` (0660 root:1004) —
handled by group `android_input` (gid 1004, matches AID_INPUT) that melissa
joins. seatd socket is group `video`(44). Perms recon: `artifacts/node-perms-probe.txt`.
`/etc/phoc.ini` MUST be world-readable or phoc segfaults on parse. Sudo is
password-gated (`melissa ALL=(ALL) ALL`) — run `det passwd` once before sudo
works. **nosuid gotcha:** Android's /data is `nosuid,nodev`, and the container
rootfs is a bind of a /data subtree, so the container `/` inherits nosuid and
sudo's setuid bit is ignored ("effective uid is not 0 … nosuid"). `guest-start`
fixes it by `mount -o remount,bind,suid,dev,exec /` inside the container
post-start (the host-side bind-remount of `$DET/guest` does NOT reach the
pivoted container root on 4.14). `det guest` = melissa shell; `det guest-root`
= root escape hatch. Known
gap: phosh runs bare (no logind), so polkit-gated actions log "No session" —
Logout/Reboot/Poweroff are fine (det-session-manager intercepts them).

**pidfd shim:** `det-pidfd-shim.so` (LD_PRELOAD) — pidfd_open→ENOSYS forces
SIGCHLD fallback. Required because waitid(P_PIDFD) is EINVAL on 4.14.

**Session manager:** `det-session-manager` owns org.gnome.SessionManager on the
session bus. Routes Logout→exit (phone mode), Shutdown→poweroff, Reboot→reboot.
Also plays gsd-power for wake: ActiveChanged(true)→AddUserActiveWatch→SetActive(false).

**Control channel:** `toggle/det-hostagent` (inotifyd-driven) watches
`/data/determination/run/control`. Guest writes commands via `/mnt/det-control`.

**Battery:** `bms` node is accurate (not `battery`). `det-battery` bind-mounts
the corrected capacity over `battery/capacity`. The bind is re-asserted every
poll pass, not once: the qpnp-smb5 charger re-enumerates its power_supply node
on USB plug/unplug and silently drops the bind (else phosh falls back to the
stuck raw value). The bind reaches UPower even though upowerd runs in its own
private mount namespace, because `/sys` is a shared mount so the pid1-ns bind
propagates in. (Separate, likely pre-existing: UPower reports `discharging`
while charging — `ac` line_power is online=0, only `pc_port`/`usb` are online=1.)

**Container PTYs:** guest-start remounts devpts + symlinks /dev/ptmx (ptmxmode=000 fix).
Same post-start block remounts `/` suid (nosuid /data would break sudo — see non-root session).

**sway is dead:** incompatible with the droidian wlroots hybrid 0.17/0.18 API.

**Never `phoc -E`:** glib child-watch broken on 4.14 (pidfd half-backport).

**ReZygisk:** native Zygisk MUST stay disabled (`zygisk=0`) or ReZygisk skips
module loading. Both ABI .so files required (arm64-v8a + armeabi-v7a).

## Current state (2026-07-14)

**Kernel #4 running** (`4.14.357-perf-g96adfa8256dc #2`, distro clang 22).
pstore/ramoops enabled. Device module v0.4.1 (versionCode=8); Aqua
v0.5.0-alpha.1 (versionCode=12) is the current source release. Guest RUNNING.

**Milestones complete:** 1 (kernel flash), 3 (guest renders on panel), 4 (input +
phosh verified, cable-free round trip, §4 signed off), 6 (SF-death Zygisk hook +
system_server freezer — full desktop-mode stability).

**Milestone 5 native phase proven:** Turnip-on-KGSL + minigbm pass the native
smoke gate, raw KMS scans out on DSI, and Plasma Mobile runs under KWin with
zink/Turnip GPU compositing and touch. The remaining M5 headline is concurrent
external convergence via the dmabuf→Android presenter bridge on DP-alt.

**Wake path VERIFIED** (power button blank/unblank works). KEY_POWER quirk removed.

**Desktop-mode crash loop FIXED (2026-07-12):** The `ss-freezer` loop in
`toggle/desktop-on` (step 3b) SIGSTOPs system_server the moment we hand off, so
its `android.display` thread can never accumulate 60s of block time and the
framework Watchdog never fires. Verified 150s soak: ss stays state=T, wlan0 stays
UP with IP, guest ping works. `desktop-off` SIGKILLs the frozen ss so init/zygote
respawns it fresh (SIGCONT would just unblock the Watchdog and it'd self-kill
from the accumulated block time). **Guest networking now works in desktop mode.**

Failed alternative: PLT-hooking `kill`/`tgkill`/`abort`/`exit`/`_exit` in
libandroid_runtime/libc/libutils/libbase/libprocessgroup from Zygisk. Hooks
registered fine but never fired — the actual Watchdog kill path doesn't go
through any of those GOT entries in system_server. Don't retry this angle.

**Other known issues:**
- phoc teardown segfaults (rc 139, cosmetic).
- matrix flat varyings (mat3/mat4) unverified in GSK shader fix.
- /sdcard (FUSE) unavailable in desktop mode (framework thrash). Drop files
  elsewhere (e.g., /data/local/tmp for adb staging).

## Next steps (see `docs/north-star.md`)

1. Audio stack (pipewire) → volume keys
2. Phosh polish (feedbackd, backgrounds)
3. §5 external convergence (DP-alt)

## adb/su/lxc quoting rule

`adb shell "su -c '<entire chain>'"` — one quoted arg or only the first command
runs as root. File drop into guest: adb push → su cp over existing guest file →
lxc-attach `/bin/cp` to final path.

## On-device paths

- Guest rootfs: `/data/determination/guest` (no `rootfs/` subdir)
- Toggle scripts deploy to: `/data/determination/bin/`
- Control channel: `/data/determination/run/control`
- LXC tools: `/data/determination/lxc/bin`
- Backups: `/sdcard/Download/boot_a-before-determination-*.img` + `artifacts/backups/`
