# Determination — project context

Android convergence layer for melissa's OnePlus 7 (`guacamoleb`, SM8150 /
Adreno 640). Android stays PID1 and live; a Debian LXC guest on the same
downstream kernel takes the display via libhybris→hwcomposer. Ships as custom
boot.img + Magisk module + Zygisk — never a ROM, never touches /system.

**Read first:** `docs/design-spec.md` (the authoritative design — §4 internal
panel handoff is the core novel work) and `docs/recon-findings.md` (ground
truth about the actual device). `README.md` has the repo map and milestone
order. Raw probe outputs live in `recon/report-*/` and `artifacts/`.

## The device (recon-verified 2026-07-01, updated 2026-07-03, don't re-derive)

- crDroid 12.11 / Android 16 (SDK 36) — NOT stock; fingerprint is spoofed to
  OnePlus Android 12. Slot `_a` (the 2026-07-03 OTA switched slots). Magisk
  30.7. The OTA replaced the Determination kernel with stock and wiped all
  Magisk modules — see State below.
- Kernel `4.14.357-openela` from crDroid's sm8150 fork (branch `16.0`).
- Composer HAL: HIDL `graphics.composer@2.1–2.4` (no AIDL composer3).
  Gralloc: QTI mapper@4.0 → libhybris pairs as gralloc4.
- binderfs already in the running kernel; guest gets a private binderfs
  instance in its IPC ns (do NOT resurrect the extra-binder-devices idea).
- Kernel opts we must add (why the rebuild exists): PID_NS, IPC_NS, USER_NS,
  CGROUP_DEVICE, CGROUP_PIDS, POSIX_MQUEUE → `kernel/determination.config`.
- DP-alt over USB-C works on this ROM (user-verified); Android's native
  desktop mode runs on it. §5 external convergence has no hardware risk.

## Talking to the phone (USB cable exists as of 2026-07-03)

- A USB cable now connects the phone (`adb devices` shows it on usb) —
  fastboot recovery is possible, so a kernel bootloop is no longer a
  dead-phone scenario. Wireless adb still works as fallback: official
  platform-tools only (distro `android-tools` pairing is broken), port
  rotates per reboot, discover via `adb mdns services`.
- **Never run `adb root`**. Root is `adb shell su -c ...` (Magisk). If su
  returns "Permission denied" silently, the Shell toggle in Magisk's
  Superuser tab is off — ask melissa to flip it (screen must be unlocked
  for grant prompts).
- Install path is the `usb-install/` Magisk "action zips" that `dd` the
  boot partition from the phone itself (Magisk app → Modules → Install from
  storage). Payload can go to an OTG drive (`./det publish`) or straight to
  `/sdcard/Download` via adb push — the Magisk app can install from either.
  Cable alternative: `usb-install/host-flash.sh check|flash|restore|verify`
  drives the same flow over adb with a host-side backup copy; dry-run safe
  mode for the zips = `touch /sdcard/Download/determination-dryrun`.

## Build system

- `kernel/build.sh`: bases the config on the RUNNING kernel's config
  (`artifacts/kernel-config-full.txt` from /proc/config.gz), merges
  `determination.config`, verifies every option took before compiling. Distro
  clang + aarch64 binutils extracted to `toolchain/` (gitignored — if
  missing, re-extract the Arch `aarch64-linux-gnu-binutils` package there,
  no root needed). Tree has the ACK LLVM= backport.
- Known risk: shipping kernel used AOSP clang 21, we build with distro clang
  22 — new warnings-as-errors may need `-Wno-` additions (KCFLAGS), not real fixes.
- dtbo is NOT rebuilt; the ROM's flashed dtbo pairs with a same-source kernel.
- `boot/repack.sh`: swaps kernel into stock boot.img via magiskboot (not
  installed yet — extract from Magisk apk), ramdisk left for Magisk to patch.
- evgrab (`tools/evgrab/`): builds with `make host CC=clang` for logic tests
  (verified working on host evdev); device build needs NDK or aarch64 gcc.

## Conventions

- Ad-hoc probe/script *outputs* get saved to `artifacts/` with descriptive
  names (melissa's standing request). Structured recon goes to `recon/report-*/`.
- Commit as work lands; author `melissa <theonest262@gmail.com>`.
- The toggle scripts' suppressor loop (desktop-on) is an acknowledged bring-up
  hack; the real fix is the Zygisk SF-death-handler hook (zygisk/README.md).
- Related-but-separate: `~/op7-port/` + pmOS memories are the *mainline*
  kernel track. Determination is deliberately downstream-kernel. Don't mix them.

## State / next steps

**2026-07-03 evening: MILESTONE 1 RESTORED — kernel #3 is flashed and
running on crDroid 12.11.** `/proc/version` = `4.14.357-perf-g96adfa8256dc
(melissa@terra) … Fri Jul 3 18:32:22 BST 2026`; `host-flash.sh verify`
green (all Determination options incl. VT/nftables/CRIU/binfmt_misc/macvlan);
WiFi green on the BUILT-IN driver (5 GHz 11ac, no kmods overlay); module
v0.1.2 installed, IPv6 forwarding on. Backups of the pre-flash boot:
`/sdcard/Download/boot_a-before-determination-20260703-185113.img` (on phone),
`artifacts/backups/` (host, gitignored), `artifacts/boot_a-crdroid-12.11.img`
(committed pristine — all three sha-identical), plus the restore zip embeds
it. Earlier that day: the 12.11 OTA had switched to slot `_a`, replaced
kernel #1 with stock, and wiped all Magisk modules; kernel #3 was rebuilt
from a clean `kernel/out` against the new running config
(`artifacts/kernel-config-full-12.11.txt`).

Kernel #3 has QCA_CLD_WLAN/GSPCA **built in** (=y) — the kmods overlay
(`magisk-module-wlan/`, keyed to kernel #1's exact uname) is obsolete; do
not reship it. The old "must rebuild modules or WiFi dies" rule is dead:
determination.config has no =m options.

MILESTONE 1 (2026-07-02, pre-OTA): kernel #1 flashed cable-free via the
`usb-install/` action zips and ran (`4.14.357-perf-g96adfa8256dc`); WiFi
vermagic gotcha found and fixed, hardware smoke test green.

Toolchain context: `boot/repack.sh` needs magiskboot from
`toolchain/usr/bin` on PATH; platform-tools at `~/platform-tools`;
toolchain/ gitignored (re-extract Arch pkgs if missing). Kernel build:
~4 min on this box.

**2026-07-04: GUEST STACK STOOD UP; blocked at the libhybris/API-36 TLS
wall.** Progress since the flash:
1. DONE — static arm64 LXC on device (`guest/build-lxc.sh`, 7 tools in
   `/data/determination/lxc/bin`). LXC 4.0.12, `-Wno-error=incompatible-pointer-
   types` for the glibc-2.40 mount_setattr clash.
2. DONE — Debian **trixie** arm64 rootfs, debootstrapped no-root (fakeroot
   --foreign + on-device --second-stage), 253 pkgs configured. Container
   boots systemd to RUNNING, zero failed units. `guest/setup-guest.sh`
   (on-device customizer, mirror of `customize-hook.sh`).
3. DONE — guest network egress. The fix was NOT nat/forward: Android's
   policy-routing rule chain ends in `from all unreachable` with no
   `lookup main`, so replies to the container were routed to nowhere.
   Fix (baked into `toggle/guest-start`): `ip rule add pref 9000 to
   192.168.117.0/24 lookup main` + `pref 21000 iif determ0 lookup wlan0`,
   plus explicit INPUT/OUTPUT/FORWARD accepts ahead of netd's chains.
   guest-start also now does the bind-remount (dev,exec,suid) and pin-dir
   creation that were previously manual.
4. DONE — libhybris bring-up, mostly. Android world is now bind-mounted at
   the **real root paths** (`/system`,`/vendor`,`/odm`,`/apex`), NOT under
   `/android/` — the partitions carry absolute symlinks into `/apex` and
   libhybris hardcodes `/system/build.prop` + a `/vendor/lib64:/system/lib64:
   /odm/lib64` default path; the `/android/` prefix dangled the apex
   symlinks and broke the bionic linker. `HYBRIS_LD_LIBRARY_PATH` adds
   `/apex/com.android.runtime/lib64/bionic` (where libc.so lives on A10+).
   `test_dlopen /system/lib64/libc.so` → rc=0: **the hybris linker loads
   bionic libc**. Droidian repo pins: keyring must come from their *git*
   (`raw.githubusercontent.com/droidian/droidian-archive-keyring/droidian/
   droidian/droidian.gpg`) — every packaged keyring deb is stale and misses
   the Jan/2025 staging key. Whole hybris stack pinned to the **z4** build
   (`*+z4+*`, May 2025) because it's the newest that installs on trixie.

**THE TLS WALL — CLEARED 2026-07-04 by building upstream libhybris.**
History: Droidian's z4 libhybris SIGSEGV'd the instant bionic ran (gdb:
`ldr x8,[x8,#2080]` inside `libc.so`, x8 garbage — bionic reading a private
TLS slot the libhybris `q` linker never set up; the documented
`tpidr_el0`-offset conflict, `droidian/libhybris@99bb609`). Ruled out:
version split, SDK override, missing linkerconfig, and the experimental
`HYBRIS_TLS_PATCH=1` patcher (present in z4, too immature). Root cause was
Droidian's fork being stale — **its last upstream merge was Aug 2024**, and
droidian1 (Dec 2025) is only a header rebuild; both predate Android 15/16
support. **Path B (newer glibc → droidian1) is DEAD** (same code). Distro
swap (Arch/Alpine) doesn't bypass a libhybris-*source* problem; Alpine=musl
is worse. See `guest/build-libhybris.sh` for the full rationale.

**Fix that worked — `guest/build-libhybris.sh`:** built `libhybris/libhybris`
master (has PR #609 "Android 15 and 16", hwc2 A16, sdk-version fix, linker
path-order fix) natively in the guest against trixie glibc 2.41. No distro
swap, no rootfs rebuild. Gotchas encoded in the script: `TMPDIR=/tmp` (Android
leaks `/data/local/tmp`), `--enable-arch=arm64` (default is 32-bit arm →
`/system/lib` not lib64), android-headers-30 (provides pkg-config module +
`hwcomposer2.h`; A16 support is runtime not header), `test_audio` build
failure is the last subdir and harmless. Installs glibc-side libs +
q/mm/n/o linkers to `/usr/local`. Run hybris progs with
`LD_LIBRARY_PATH=/usr/local/lib`,
`HYBRIS_LD_LIBRARY_PATH=/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic`,
`EGL_PLATFORM=hwcomposer`. **Proof:** this upstream `test_hwcomposer` prints
`Android SDK version 36`, loads the linker, and runs past the old crash —
the TLS wall is gone.

**2026-07-04 evening: §3 GATE PASSED — the guest renders on the panel.**
`test_hwcomposer` inside the container: composer@2.4 client bound over the
HOST's hwbinder, display 1080x2340, **GLES 3.2 on Adreno 640 in the guest**,
~99.9% GPU busy with SF stopped, clean exit + SF restore. Evidence:
`artifacts/guest-hwc2-gate-20260704.txt`; repro `guest/hwc-smoke.sh`
(adb-su runner, always restores SF). The three fixes:
1. `libhwc2_compat_layer.so` — standalone A16 NDK cross-build against
   pulled device libs, `hwc2-compat/build.sh` (951141a + follow-ups: strip
   libgui via compiled-in HdrMetadata.cpp + `--as-needed`; installs to
   guest `/usr/lib/android/`). No Halium/ROM tree needed.
2. libhybris hooks gap: bionic-only `__ctype_get_mb_cur_max` reads bionic
   TLS `tp[-1]` (absent on glibc threads) → SIGSEGV in vendor libc++'s
   `locale::classic()` during android_dlopen of the compat layer. hooks_mm
   hooks the locale.h family but missed it. Hook it + the `*_l` family
   (hooked newlocale hands out GLIBC locale_t — bionic `*_l` consumers must
   never see one) + mb/wc conversions. Patch embedded in
   `guest/build-libhybris.sh` (upstream-able); rebuild = `make -C
   /root/build/libhybris/hybris/common install` in-guest.
3. Binder: guest had none (private-binderfs entry silently never mounted).
   mknod replicas of binderfs nodes open with **ENXIO** — nodes are backed
   by the binderfs superblock, so BIND-MOUNT host
   `/dev/binderfs/{binder,hwbinder,vndbinder}` (in `guest/lxc/config` now;
   needs container restart via guest-start).
Backlight gotcha (solved the eternal "dark panel"): stopping SF ZEROES
`/sys/class/backlight/panel0-backlight/brightness` — guest frames reached
scanout unlit. desktop-on step 4b + a keeper loop force 600 while in
desktop mode; desktop-on currently runs test_hwcomposer as a TEMP stand-in
compositor (block marked TEMP, swap back to sway when it lands).
Known flake: composer-client creation right after SF stop can race SF's
client teardown ("failed to create composer client", rc 134) — retry.
Non-blockers: `libui_compat_layer.so` not found (gralloc falls back; could
cross-build like hwc2 later); guest property_set fails (no property
service socket).

adb/su/lxc quoting (this, NOT SELinux, caused every mystery denial):
`adb shell "su -c '<cmds>'"` — whole chain in ONE quoted arg, or only the
first command runs as root. File drop into guest: adb push to
/sdcard/Download → su cp over an EXISTING guest-rootfs file → lxc-attach
`/bin/cp` to final name (direct exec, no inner shell).

**2026-07-05/06: the NO_RESOURCES/FMQ wall + the REAL black-panel story.**
Symptom: every guest hwc2 validate returned error 6 (NO_RESOURCES); root
cause chain: composer FMQ (command queue) creation falls back to ashmem →
modern libcutils opens `/dev/ashmem<boot_id>` (per-boot name) → container
had neither node → writeQueue failed CLIENT-side. Three-part fix, all
verified 2026-07-06 (`artifacts/guest-hwc2-ashmem-fix-20260706.txt`,
validate/present all error=0, user-visible render): (1) bind host
`/dev/ashmem` in `guest/lxc/config`; (2) `guest-start` mknods the per-boot
`/dev/ashmem<boot_id>` (plain misc chardev 10:59 — mknod fine, the binderfs
ENXIO rule doesn't apply); (3) `ashmem_create_region` interpose with memfd
fallback + fmq/hidl `logError`→stderr interpose in
`hwc2-compat/diag/hwc2_compat_extra.cpp` (guest has no logd — ALOG is a
black hole). Also that session: (a) TRUE black-panel root cause = SDM
starts every composer client at brightness 0 and DSPP-dims its output to
black — one `setDisplayBrightness(1.0)` after power-on fixes it (b182d86;
wired through libhybris hwc2 wrappers in `guest/build-libhybris.sh`);
(b) the ACTIVE backlight node is `/sys/class/backlight/backlight` (max
4095, keeper writes 2048) — `panel0-backlight` is INERT; (c) in-guest
test_hwcomposer patched to render continuously (upstream exits after ~24s
tearing down the display) — desktop-on now supervises ONE long-lived
instance with fast-fail backoff, logging to `log/compositor.log`
(stdbuf -oL required or the log stays empty). Old "composer-client race"
flake note: measured never firing across many relaunches; treat as solved.

**2026-07-06: §3 COMPLETE — phoc + foot terminal live on the panel.**
The real compositor is **phoc 0.47** (droidian branch
`group/102/keypad-slide-lights`) on the **droidian wlroots fork**
(`feature/next/backport-0.18`, their live line: 0.17.4 + backported 0.18
APIs + hwcomposer backend + android renderer), all built IN-GUEST against
our upstream libhybris — `guest/build-wlroots-phoc.sh` (one script, all
gotchas encoded). Verified: phoc on HWCOMPOSER-1 1080x2340, GLES 3.2
Adreno 640, hybris EGL 1.5; foot as a separate Wayland client, visible and
readable (photo-confirmed); grim screencopy works in-compositor. Evidence:
`artifacts/guest-phoc-foot-v2-20260706.txt`, `guest-phoc-shot-20260706.png`.
Hard-won facts (all encoded in the script + toggles):
- sway is a DEAD END against this fork (1.9 too old / 1.10 too new for its
  hybrid 0.17/0.18 API); phoc group/102 pins exactly wlroots >=0.17 <0.18
  and REQUIRES xwayland-enabled wlroots (unguarded includes/fields).
- libdroid: build-dep of the wlroots hwc backend; glibc-native (gio +
  libgbinder). Build from source — the droidian BINARY deb drags their
  stale TLS-broken libhybris in.
- Upstream libhybris needed `HWCNativeWindowSetBufferCount` (droidian API,
  triple buffering) — added via perform(); patch in build-libhybris.sh,
  which now also force-installs the patched hwc2 header (the include
  install lagged the source and broke the first wlroots compile).
- The SDM DSPP-dim strikes ANY new composer client: wlroots hwcomposer2.c
  patched to setDisplayBrightness(1.0) after power-on (in the build script).
- Runtime MUST use LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/
  aarch64-linux-gnu — droidian z4 libhybris debs still sit in
  /lib/aarch64-linux-gnu and win ld.so.conf ordering otherwise.
- glib child-watch is broken on this pidfd-less 4.14 kernel
  (waitid(P_PIDFD) EINVAL): NEVER `phoc -E` — phoc thinks the session died
  and exits (will bite anything glib-spawn-based, e.g. phosh, later).
  desktop-on launches compositor and clients separately.
- Container PTYs: inherited devpts has ptmxmode=000, terminals die with
  "failed to open PTY". lxc.pty.max is NOT honored by our static LXC
  4.0.12; guest-start remounts devpts + symlinks /dev/ptmx post-start.
- Panel is ~403dpi: /etc/phoc.ini ([output:HWCOMPOSER-1] scale=3,
  guest/phoc.ini) or text is unreadable.
- dmabuf is unavailable (no EGL_EXT_image_dma_buf_import via hybris);
  clients render over wl_shm — fine for terminals, revisit for phosh/apps.
- phoc teardown segfaults after its wayland display is destroyed
  (rc 139 / SIGSEGV at exit) — post-cleanup, cosmetic so far; watch it.
desktop-on now supervises phoc (fast-fail backoff) + a foot client loop;
desktop-off pkills foot then phoc (TERM) before SF restart.

**2026-07-06/07: §4 GUEST INPUT + PHOSH WORKING — melissa touch-verified
(swipe-unlock, app grid, squeekboard typing).** Evidence:
`artifacts/guest-phosh-touch-20260706.png`, `guest-input-bringup-20260706.txt`.
Stack: phosh 0.46 + squeekboard 1.43 (trixie debs) on our phoc/wlroots,
`WLR_BACKENDS=hwcomposer,libinput`. Guest root password: 1234 (phosh
lockscreen PAM auth). What it took (encoded in guest/setup-input.sh,
build-wlroots-phoc.sh PATCH 2, toggle/desktop-on 5d/5e, guest-start):
1. wlroots EVIOCGRAB handoff: grab on a dup'd fd in a detached retry
   thread per device (grabs live on the open file description); desktop-on
   kills evgrab once phoc's socket is up. Retry window 10min and the 5d
   watcher is uncapped — the first run's 30s/120s caps both expired during
   live debugging and left the session grabless (fixed same night).
2. libinput needs hand-fed udev properties (udevd can't run: ro /sys) —
   det-input-udevdb writes /run/udev/data — AND quirks
   (/etc/libinput/local-overrides.quirks): the touchpanel advertises
   min==max ABS_MT_WIDTH_MAJOR/_PRESSURE and libinput hard-rejects the
   whole device otherwise.
3. seatd (libseat session for the wlroots libinput backend): CONFIG_VT in
   kernel #3 makes seatd VT-bound → container MUST have /dev/tty0-2
   (guest-start mknods them) or every client times out "waiting session to
   become active" and phoc dies at startup.
4. THE pidfd HALF-BACKPORT (real mechanism behind "never phoc -E", now
   proven): pidfd_open(434) WORKS on this kernel but waitid(P_PIDFD) is
   EINVAL → glib child-watch fires with bogus status. det-pidfd-shim.so
   (LD_PRELOAD, guest) makes pidfd_open return ENOSYS → SIGCHLD fallback.
   Verified A/B. Required for phosh app launching.
5. phosh ABORTS (fatal GIO error) without gnome-settings-daemon-common —
   it's only a Recommends; also adwaita-icon-theme for squeekboard keys.

§4 KNOWN ISSUES: (a) power button: phosh blanks the screen but phoc's
hwcomposer output RE-ENABLE never fires — "power kills the session";
KEY_POWER is quirked inert (qpnp_pon quirk) until the wake path is
debugged. Recovery from a blanked/wedged session: `pkill phoc` in guest —
the desktop-on supervisor relaunches everything in ~10s, grabs included.
(b) volume keys reach phosh; no audio stack in the guest yet so nothing
happens. (c) ROOT CAUSE FOUND (2026-07-07 00:30): **in desktop mode
system_server crash-loops** (WindowManager dies on the stopped SF; ~50s
per cycle, verified via `ps -o etime` + logcat crash buffer) — every
restart reprograms netd (flushing our iptables/ip-rules; guest-start now
runs a 20s `net-keeper` loop for that) and bounces WiFi, which eventually
stays DOWN (wlan0 DOWN, the `wlan0` route table deleted) → guest fully
offline while in desktop mode. Milestone 6 (Zygisk hook on
system_server's SF-death handling) is therefore URGENT, not polish; until
then guest networking is only reliable in phone mode, and long desktop
sessions thrash the framework (suspected contributor to the 07-06 kernel
panic via wlan driver churn). Package-install workaround if needed:
download deb on host → adb push → dpkg -i. (d) grim "failed to copy
output" = the output is blanked, not a grim bug.

§4 POLISH (2026-07-07, guest/setup-polish.sh — idempotent, run in PHONE
mode for network): gnome-console/calculator/text-editor/clocks +
gnome-backgrounds installed; phosh favorites + wallpaper set; **idle-delay
forced 0** (an idle blank would hit the same broken wake path as the
power button and soft-kill the session on a timer); **notch**: DT
compatibles are generic qcom,sm8150* and gmobile 0.3.1 reads ONLY
embedded GResources, so setup-polish.sh rebuilds libgmobile from source
with the fajita (same 1080x2340 waterdrop glass) panel JSON registered
under qcom,sm8150-mtp + qcom,sm8150, installed to /usr/local. BOTH phoc
and phosh need LD_LIBRARY_PATH=/usr/local/... to load it (desktop-on
exports it for the 5e client session too — phosh computes the top-bar
notch margin).

DEVICE STABILITY (2026-07-06 evening): two spontaneous reboots + one
battery shutdown + one REAL kernel panic into Qualcomm crashdump
(USB 05c6:900e QUSB_BULK; hold Power+VolUp 10-15s to exit) — all during
guest apt traffic while the battery was near-dead. melissa: not battery.
NO PSTORE in kernel #3 so the panic text is lost — add CONFIG_PSTORE +
PSTORE_RAM/RAMOOPS to determination.config for kernel #4. Until then run a
`dmesg -w` tap to a host file during risky/network-heavy guest work.

**2026-07-08: RENAMED DecemberOS -> Determination (full sweep) + cable-free
UX round-trip. DEPLOYED + verified on-device** (migrated, module v0.2.0
installed, guest RUNNING under new paths, control channel round-trips). Two
bring-up gotchas, now fixed & encoded:
- The static LXC binaries have `/data/decemberos/run` **baked in**
  (`--with-runtime-path`); `/run` is read-only on Android so post-migration
  lxc-start died `Failed to create lock for guest`. Fix: guest-start aliases
  `/data/decemberos -> /data/determination` (persists on /data). Proper fix =
  rebuild lxc/bin via guest/build-lxc.sh (already retargeted); then the symlink
  is redundant. The guest rootfs is `/data/determination/guest` **directly**
  (no `rootfs/` subdir — run_polish.sh's path was wrong; run_controls.sh drops
  into the guest's /root instead).
- `lxc-attach` hands scripts a **minimal PATH** (no /usr/bin) — setup-controls.sh
  must `export PATH=...` or systemctl/gsettings/dbus-run-session silently no-op.
1. RENAME. Repo-wide: brand, `/data/decemberos` -> `/data/determination`, the
   `dos` CLI -> `det`, `$DOS` -> `$DET`, bridge `decembr0` -> `determ0`, guest
   tool prefix `dos-` -> `det-`, Magisk module id `decemberos` -> `determination`,
   `kernel/decemberos.config` -> `determination.config`. Historical `artifacts/`
   evidence, committed binaries, and upstream/vendored trees left untouched (the
   `DOS-*` log prefixes in `hwc2-compat/diag` stay — they pair with saved logs).
   ON-DEVICE MIGRATION (run once, phone mode): `det migrate` (or
   `migrate-to-determination.sh`) moves `/data/decemberos` -> `/data/determination`
   in place (rootfs preserved), renames guest `dos-*` artifacts, flags the old
   module for removal. THEN reinstall the new `determination-magisk-*.zip` and
   reboot. The new lxc config needs a container restart to bind the control dir.
2. GUEST->HOST CONTROL CHANNEL (the "leave desktop mode / power off from inside
   phosh" gap — there's no root shell in the guest). `toggle/det-hostagent`
   (root, launched single-instance by guest-start) watches
   `/data/determination/run/control`, bind-mounted into the guest at
   `/mnt/det-control` (lxc config). Guest drops `exit`/`reboot`/`poweroff`
   command files; agent runs desktop-off / `svc power` accordingly.
3. IN-DESKTOP TRIGGERS (`guest/setup-controls.sh`, run via `run_controls.sh`):
   `det-signal` helper + three app-grid launchers (Exit to Phone / Power Off /
   Restart) + systemd shutdown-hook units (`det-{poweroff,reboot}-signal.service`,
   WantedBy the target, ordered `Before=umount.target` to dodge the shutdown
   unmount race) that map phosh's NATIVE power menu onto host actions. Exit
   launcher pinned to phosh favourites. UNVERIFIED on-device — the power-menu
   path (systemd isolate -> our oneshot before unmount) especially needs a live
   check; the app-grid launchers write the file while fully up so they're the
   reliable core.
4. ANDROID COMPANION APP (`companion/`, Kotlin/Material3, minSdk 26). Phone-side
   ENTER: live status (mode/guest/SF/agent/kernel), one-tap Enter Desktop Mode
   (launches desktop-on DETACHED via setsid so it survives the SF handoff killing
   the app), a Quick Settings tile, Exit fallback. Shells to Magisk `su`, holds
   no root. Enter (app) + exit/power (guest launchers) = full cable-free round
   trip. No wrapper jar committed (open in Studio or `gradle wrapper`). Build/run
   UNVERIFIED (no Android SDK on this box).

Companion APK: **builds + installed** (`com.determination.companion`). No-root
Android toolchain lives at `~/android-sdk` (JDK17 + cmdline-tools + platform-34
+ gradle-8.7, all gitignored); build = `~/android-sdk/gradle-8.7/bin/gradle
--no-daemon assembleDebug` in `companion/` (needs `local.properties` sdk.dir).
Phosh launcher gotcha: melissa's `app-filter-mode=adaptive` HIDES any .desktop
without `X-Purism-FormFactor=...Mobile;` — every guest launcher must carry it.

07-08 LIVE TEST was cut short: the desktop handoff came up clean (phosh ready
0.65s, input handed to guest, host-side desktop-off recovered it), but the
battery was genuinely low and the phone **died on plug-in** before the on-panel
tap of the (now filter-fixed) Exit launcher + phosh power-menu Power Off/Restart
could be confirmed — still UNVERIFIED. In desktop mode the framework thrash also
knocks out /sdcard (FUSE) — drop files elsewhere (su stdin heredoc / guest /root)
or work in phone mode.

BATTERY GAUGE (07-08, important): the OP7 `battery` power_supply node reports a
**stuck/garbage capacity** on this kernel — frozen `charge_counter=37000` and a
bogus `temp=41.5C`, byte-identical across reboots (the OnePlus `oplus_chg`
gauge-protect/AFI logic misfiring without vendor bits). The ACCURATE gauge is
the `bms` node (type=BMS, moving counter, sane temp) — but UPower only honours
`type=Battery`, so phosh reads the broken node and shows ~1%. Android has its
own vendor path and reads correctly. Fix = `det-battery` (setup-controls.sh): a
guest daemon that bind-mounts a file holding the live `bms` capacity over
`battery/capacity` **in the guest mount ns only** (verified: guest node 1->7,
host node still 1). Bind-over-sysfs works here (privileged container). NOTE this
means a low battery genuinely reads low on both — it is NOT purely cosmetic; the
cell was actually near-empty. Wall-charge before heavy/desktop testing.

**2026-07-08 late: companion Material-You pass + SESSION-MANAGER SHIM (logout
== phone mode).** Both deployed to device; shim verified in isolation, live
routing through phosh UI still to eyeball.
- companion app: Material3 DynamicColors.DayNight (wallpaper palette on A12+),
  edge-to-edge with transparent bars + window-inset padding, soul-tinted
  gradient bg (light+dark), translucent "glass" MaterialCardView status,
  adaptive margins (values-sw600dp), pixel-art red SOUL icon/header. Rebuilt +
  reinstalled (com.determination.companion, versionName 0.2.0).
- **det-session-manager** (guest/setup-controls.sh): phosh + squeekboard were
  failing to register with org.gnome.SessionManager (we run phosh bare — no
  gnome-session; `phoc -E` is banned on this kernel). New minimal gi/GDBus
  service OWNS that name on phosh's session bus and routes the verbs to the
  host control channel: Logout()->det-signal exit (**log out of desktop ==
  hand display back to phone** — melissa's idea), Shutdown()->poweroff,
  Reboot()->reboot. Full RegisterClient/ClientPrivate handshake + Inhibit/
  CanShutdown stubs + props. desktop-on 5e launches it inside dbus-run-session
  BEFORE phosh (`${SM:+$SM & sleep 0.3;}`). On-device isolation test (scratch
  session bus) green: owns name, CanShutdown=true, RegisterClient returns a
  client objectpath, EndSessionResponse acks. UNVERIFIED: whether phosh's
  power menu surfaces a Logout affordance / routes Shutdown-Reboot through the
  shim vs logind — needs a live desktop-mode tap-test. On-device desktop-on
  lives at `/data/determination/bin/desktop-on` (toggle scripts deploy to
  `.../bin/`, NOT `.../toggle/`).

**2026-07-08: GPU APP BUFFERS designed + wired host-side (NOT yet
device-tested — melissa asked to hold phone changes).** Full design:
`docs/gpu-app-buffers.md`. Key finding: the zero-copy path already exists
in what we ship — hybris wayland EGL platform (client side; our libhybris
build already had `--enable-wayland`) + wlroots' server-side
`android_wlegl` + EGLImage import in the android renderer. The old "dmabuf
unavailable / clients are wl_shm" note was really missing WIRING, not a
missing component. Changes: desktop-on 5e client session now exports
`EGL_PLATFORM=wayland HYBRIS_EGLPLATFORM=wayland`, client
`HYBRIS_LD_LIBRARY_PATH`, `GSK_RENDERER=ngl` (plain eglGetDisplay defaults
to hwcomposer and would fight phoc for the composer; the vendor EGL must
resolve in client processes too); /etc/profile.d/hybris.sh default flipped
to wayland (setup-guest.sh + customize-hook.sh); build-wlroots-phoc.sh
gained an eglplatform_wayland.so prereq check; NEW `guest/gpu-smoke.sh`
(`prep` = phone mode, installs glmark2-es2-wayland + wayland-utils; bare =
desktop-mode gate: android_wlegl global present, glmark2 shows vendor
GL_RENDERER + FPS, GTK4 app maps HYBRIS libEGL under GDK_DEBUG=opengl).
Deploy = push desktop-on to `/data/determination/bin/` + write the new
profile.d file in the guest; NO rebuilds needed. ABI hazard (wlroots
hand-mimics hybris' RemoteWindowBuffer layout) + the wayland-platform
abort()-when-no-wlegl failure mode are documented in the doc.

**2026-07-10: GPU APP BUFFERS WORK — the white-window bug is DEAD.** Root
cause of "apps launch to a white screen": the Adreno 640 blob (V@0502)
mishandles STRUCT VARYINGS matched by name across stages — a `flat in
Rect/RoundedRect` read as a whole struct (function arg) yields zeros
(sometimes a hard link failure), while per-field access works. Every GSK
fragment shader ends in `rect_coverage(_rect,_pos)` → alpha=0 → NO GSK
shader draw ever landed pixels (all previously-visible app content was
glClear/occlusion output). Fix: custom `glShaderSource` in the hybris
glesv2 wrapper rewrites GSK fragment sources (detects unexpanded
`PASS_FLAT(n) Rect/RoundedRect NAME;` decls — GTK sends macros unexpanded)
to rebuild structs from fields (`_rect` → `Rect(_rect.bounds)`); opt-out
`HYBRIS_NO_GSK_VARYING_FIX=1`. Deployed in-guest (glesv2 rebuilt+installed)
AND encoded in `guest/build-libhybris.sh` along with the two other GTK4
blockers from 07-09: the epoxy `EGL_EXT_device_query` abort (display ext
string filter) and the `eglSwapBuffersWithDamageKHR` override (GDK prefers
the KHR name; without it windows never map). Verified on device:
`gtk4-rendernode-tool` ngl == cairo reference (texture + text nodes),
gnome-calculator renders real widgets on the panel. Evidence chain +
bisect log: `artifacts/guest-gsk-struct-varying-fix-20260710.txt`, calc
screenshot `artifacts/guest-gsk-fix-calc-20260710.png`. gpu-smoke.sh:
check 4 no longer uses GDK_DEBUG=opengl; NEW check 5 = ngl text-node
render must have >10 colors (regression gate for this fix). Debug tooling
that cracked it (kept in guest /root): libglspy.so GL-call spy (soname-
patched over hybris libEGL/GLESv2 in /root/spy; needs
GDK_GL_DISABLE=buffer-storage — the spy breaks glBufferStorageEXT
forwarding) + texprobe4/5 (verbatim-GSK-shader probes, phone-mode
surfaceless). Headless repro recipe: `gtk4-rendernode-tool render x.node
out.png` in desktop mode. apitrace: dead end on hybris, don't retry.
STILL OPEN on this front: full gpu-smoke gate re-run (glmark2/zero-copy
numbers), matrix flat varyings (mat3/mat4) unverified — revisit if
colormatrix/cicp nodes misrender.

**2026-07-10 late: PERF/QoL PASS — deployed to device (toggles pushed to
`/data/determination/bin`, hostagent restarted + probe-verified, guest trim
run; the faster desktop-on/off path itself is NOT yet exercised — needs the
next real toggle).** What changed:
- `desktop-off`: fixed `sleep 1`+`sleep 2` replaced with bounded 0.1s polls
  (guest pids are visible to host `pgrep` — init pid ns); 3 client-kill
  lxc-attaches collapsed to 1. Typical exit is ~2s faster.
- `desktop-on`: suppressor + backlight keeper merged into ONE 1s loop (also
  more correct: every SF re-stop re-zeroes the BL); 5d wayland-socket watch
  now tests `/proc/<guest-init>/root/run/user/0/wayland-0` from the host
  (verified visible) at 0.3s instead of forking lxc-attach every 1s — faster
  input handoff; 5e client socket wait 0.2s ticks.
- `det-hostagent`: event-driven via toybox `inotifyd` — PROG must `kill $PPID`
  (inotifyd exits neither on PROG rc nor on a `|head -1` reader; measured) with
  a 15s timeout safety rescan; idle cost fell from 2 forks/s to 2 per 15s,
  command latency ~instant. Polling fallback kept.
- `guest-start`: 3 post-start fixup attaches (ashmem/devpts/VT) merged into 1.
- Log rotation (keep newest 128K past 256K) in desktop-on/hostagent/
  guest-start(lxc.log)/service.sh — lxc.log was 673K and growing.
- NEW `guest/setup-trim.sh` (+`run_trim.sh`): masks apt-daily{,-upgrade}
  (unattended apt traffic == the 07-06 instability correlate), e2scrub_all,
  fstrim; disables avahi+cron; caps journald 32M; apt no-recommends default +
  dpkg path-excludes for man/doc; purged existing doc/man/apt-cache —
  **reclaimed 722 MB**. `systemctl reset-failed` needed after `mask --now`
  (cosmetic "degraded" otherwise). Guest verified `running`, 8 services.
- `det` CLI: new `det guest [cmd]` (lxc-attach shell), `det on`/`det off`
  (setsid-detached toggles), `det log [name] [n]`.
The lxc-attach "Unsupported config key lxc.seccomp" warning is baked into the
static binary (no seccomp support), NOT from our configs — cosmetic, ignore.

NEXT: (07-08 remaining, once charged) tap-test the Exit launcher + power menu on
the panel; confirm phosh registers with the session-manager shim (no more
"org.gnome.SessionManager not provided" warnings) and that Logout/power route
to the host; try the companion app's Enter Desktop Mode + QS tile (grant it su).
Consider rebuilding lxc/bin (build-lxc.sh) to drop the /data/decemberos symlink.
Then: debug the phoc output-power wake path (power button); guest DNS
flakiness root cause; audio stack (pipewire) → volume keys + calls-less
phone basics; phosh polish (feedbackd, backgrounds); pstore into kernel
#4; then §5 external convergence. Android-side §4 stays proven
(2026-07-03 round trip); full desktop-off regression after each session.

NOTE: the running guest's apt state (gdb, linkerconfig, the z4 downgrade,
libtls-padding0) and the runtime mounts/iptables/ip-rules do NOT persist a
reboot — persistence is via `toggle/guest-start` + the on-device rootfs on
`/data`, which does persist. A clean rebuild should go through
`guest/setup-guest.sh`.
