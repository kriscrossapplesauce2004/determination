---
name: det-guest
description: >-
  Bring up and debug the Determination Linux guest desktop on the OnePlus 7
  panel — libhybris, hwcomposer/hwc2-compat, phoc/wlroots, phosh, squeekboard,
  the backlight/black-panel problem, guest input/touch, and the known
  open issues with their recovery moves. Use when a guest render/compositor/
  input/graphics thing is broken or being built. Triggers: libhybris, phoc,
  phosh, wlroots, hwcomposer, EGL, black panel, backlight, squeekboard, touch
  input, guest desktop, container won't render.
---

# Guest desktop bring-up & debugging

The graphics stack, all built **in-guest** by `guest/build-*.sh` (each script
encodes its own gotchas — read it before rebuilding):

- **libhybris** upstream master (has PR #609 Android 15/16) — NOT droidian's
  fork (stale, TLS-broken). `guest/build-libhybris.sh`.
- **hwc2-compat** standalone A16 HWC2 adaptation layer — `hwc2-compat/build.sh`.
- **phoc 0.47** (droidian `group/102`) on the **droidian wlroots fork** —
  `guest/build-wlroots-phoc.sh`. sway is a dead end against this fork.
- **phosh 0.46 + squeekboard** (trixie debs). Guest root password: `1234`.

## Runtime env (get these wrong → dlopen crashes / 32-bit libs / black screen)

```
LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/aarch64-linux-gnu
HYBRIS_LD_LIBRARY_PATH=/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
EGL_PLATFORM=hwcomposer
WLR_BACKENDS=hwcomposer,libinput
```
`/usr/local` must win over the stale droidian z4 debs in
`/lib/aarch64-linux-gnu` — hence the explicit `LD_LIBRARY_PATH` ordering.

## Symptom → fix table (all previously root-caused; don't re-derive)

- **Black / dark panel.** SDM starts every composer client at brightness 0 and
  DSPP-dims to black → one `setDisplayBrightness(1.0)` after power-on (baked
  into the libhybris + wlroots builds). The **active** backlight node is
  `/sys/class/backlight/backlight` (max 4095), NOT `panel0-backlight` (inert).
  Stopping SF zeroes brightness → desktop-on runs a keeper loop.
- **`NO_RESOURCES` / error 6 on validate.** ashmem: bind host `/dev/ashmem` +
  `mknod` the per-boot `/dev/ashmem<boot_id>` (guest-start does both).
- **Binder ops fail (ENXIO).** `mknod` replicas don't work — binderfs nodes are
  superblock-backed. **Bind-mount** host `/dev/binderfs/{binder,hwbinder,
  vndbinder}` (in `guest/lxc/config`; needs container restart via guest-start).
- **phoc self-exits / "session died" / app launch fails.** This 4.14 kernel
  half-backports pidfd: `pidfd_open` works but `waitid(P_PIDFD)` is EINVAL →
  glib child-watch fires bogus. **Never `phoc -E`.** Launch compositor and
  clients separately; `LD_PRELOAD` `dos-pidfd-shim.so` for phosh so app
  launching falls back to SIGCHLD.
- **No touch / device rejected.** libinput needs hand-fed udev props
  (`dos-input-udevdb`, udevd can't run on ro `/sys`) + a quirk for the
  touchpanel's min==max `ABS_MT_WIDTH_MAJOR`/`_PRESSURE`. seatd is VT-bound
  (CONFIG_VT) → guest needs `/dev/tty0-2` (guest-start mknods them).
- **No logs.** Guest has no logd — ALOG is a black hole. Diagnostics interpose
  fmq/hidl `logError` → stderr (`hwc2-compat/diag/…`). Evidence → `artifacts/`.

## Persistence

Runtime mounts, iptables, ip-rules, and the guest's live apt state (z4
downgrade, gdb, etc.) do **NOT** survive a reboot. They're re-applied by
`toggle/guest-start`; the rootfs on `/data` persists. A clean rebuild goes
through `guest/setup-guest.sh`, then `guest/setup-input.sh` /
`setup-polish.sh`.

## Known OPEN issues (not yet solved — set expectations before promising a fix)

- **Power button kills the session.** phosh blanks; phoc's hwcomposer output
  re-enable never fires. `KEY_POWER` is quirked inert until the wake path is
  debugged. Recovery = `pkill phoc`.
- **No audio stack** in the guest (volume keys reach phosh, do nothing).
- **`system_server` crash-loops in desktop mode** → reprograms netd, bounces
  WiFi, guest goes offline; long sessions thrash the framework. The fix is the
  Milestone-6 Zygisk SF-death hook (`zygisk/`). Until then do network work in
  phone mode. See `[[det-phone]]`.

Reach the device via the `[[det-phone]]` helper; kernel/flash work is
`[[det-buildflash]]`.
