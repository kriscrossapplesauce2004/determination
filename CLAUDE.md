# DecemberOS — project context

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
  30.7. The OTA replaced the DecemberOS kernel with stock and wiped all
  Magisk modules — see State below.
- Kernel `4.14.357-openela` from crDroid's sm8150 fork (branch `16.0`).
- Composer HAL: HIDL `graphics.composer@2.1–2.4` (no AIDL composer3).
  Gralloc: QTI mapper@4.0 → libhybris pairs as gralloc4.
- binderfs already in the running kernel; guest gets a private binderfs
  instance in its IPC ns (do NOT resurrect the extra-binder-devices idea).
- Kernel opts we must add (why the rebuild exists): PID_NS, IPC_NS, USER_NS,
  CGROUP_DEVICE, CGROUP_PIDS, POSIX_MQUEUE → `kernel/decemberos.config`.
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
  storage). Payload can go to an OTG drive (`./dos publish`) or straight to
  `/sdcard/Download` via adb push — the Magisk app can install from either.
  Cable alternative: `usb-install/host-flash.sh check|flash|restore|verify`
  drives the same flow over adb with a host-side backup copy; dry-run safe
  mode for the zips = `touch /sdcard/Download/decemberos-dryrun`.

## Build system

- `kernel/build.sh`: bases the config on the RUNNING kernel's config
  (`artifacts/kernel-config-full.txt` from /proc/config.gz), merges
  `decemberos.config`, verifies every option took before compiling. Distro
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
  kernel track. DecemberOS is deliberately downstream-kernel. Don't mix them.

## State / next steps

**2026-07-03 evening: MILESTONE 1 RESTORED — kernel #3 is flashed and
running on crDroid 12.11.** `/proc/version` = `4.14.357-perf-g96adfa8256dc
(melissa@terra) … Fri Jul 3 18:32:22 BST 2026`; `host-flash.sh verify`
green (all DecemberOS options incl. VT/nftables/CRIU/binfmt_misc/macvlan);
WiFi green on the BUILT-IN driver (5 GHz 11ac, no kmods overlay); module
v0.1.2 installed, IPv6 forwarding on. Backups of the pre-flash boot:
`/sdcard/Download/boot_a-before-decemberos-20260703-185113.img` (on phone),
`artifacts/backups/` (host, gitignored), `artifacts/boot_a-crdroid-12.11.img`
(committed pristine — all three sha-identical), plus the restore zip embeds
it. Earlier that day: the 12.11 OTA had switched to slot `_a`, replaced
kernel #1 with stock, and wiped all Magisk modules; kernel #3 was rebuilt
from a clean `kernel/out` against the new running config
(`artifacts/kernel-config-full-12.11.txt`).

Kernel #3 has QCA_CLD_WLAN/GSPCA **built in** (=y) — the kmods overlay
(`magisk-module-wlan/`, keyed to kernel #1's exact uname) is obsolete; do
not reship it. The old "must rebuild modules or WiFi dies" rule is dead:
decemberos.config has no =m options.

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
   `/data/decemberos/lxc/bin`). LXC 4.0.12, `-Wno-error=incompatible-pointer-
   types` for the glibc-2.40 mount_setattr clash.
2. DONE — Debian **trixie** arm64 rootfs, debootstrapped no-root (fakeroot
   --foreign + on-device --second-stage), 253 pkgs configured. Container
   boots systemd to RUNNING, zero failed units. `guest/setup-guest.sh`
   (on-device customizer, mirror of `customize-hook.sh`).
3. DONE — guest network egress. The fix was NOT nat/forward: Android's
   policy-routing rule chain ends in `from all unreachable` with no
   `lookup main`, so replies to the container were routed to nowhere.
   Fix (baked into `toggle/guest-start`): `ip rule add pref 9000 to
   192.168.117.0/24 lookup main` + `pref 21000 iif decembr0 lookup wlan0`,
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

**THE WALL (spec §3 gate not passed):** `getprop`/`test_hwcomposer` SIGSEGV
the instant bionic code runs (test_dlopen is fine because it never executes
bionic). gdb: crash at `ldr x8,[x8,#2080]` inside `libc.so` with x8 garbage,
x0=-1 — bionic reading a thread-local slot the libhybris **q** linker
(newest it ships, ~API-29) never set up. Ruled out: version split (whole
stack forced to z4, still crashes), SDK override (29/30/34, no change),
missing `/linkerconfig/ld.config.txt` (generated it via the apex
`linkerconfig` binary — 258 KB, still crashes identically). Root cause is a
**TLS/thread-structure layout mismatch: this crDroid base is Android 16 /
API 36 bionic, newer than Droidian's libhybris targets.**

**Forward path (recon done 2026-07-04, decision pending):** The wall is a
libhybris *source-version* problem, NOT glibc/distro.
- The crash is the documented "private bionic TLS slot" conflict
  (`droidian/libhybris@99bb609`, "experimental TLS access patcher for
  aarch64"): GLES/HAL drivers access bionic TLS at fixed `tpidr_el0` offsets,
  inlined so unhookable; glibc has no notion of that reserved area. The
  patcher (enable with **`HYBRIS_TLS_PATCH=1`**, NOT `HYBRIS_PATCH_TLS`) is
  present in our z4 build but too immature — getprop still SIGSEGVs with it
  on, no patcher debug output.
- **Path B is DEAD:** droidian1 (Dec 2025) is a header-only rebuild; the
  Droidian fork's last upstream merge was **Aug 2024**. Its debs at ANY glibc
  predate Android 15/16 support. Rebuilding on sid/forky (glibc 2.42, avail)
  to install droidian1 would ship identical TLS code — no help.
- **Best path — build UPSTREAM libhybris from source.** `libhybris/libhybris`
  master added real A16 support: PR #609 "Add support for Android 15 and 16"
  (merged 2026-03-25), HWC3/AIDL composer (#578), `get_application_target_sdk_
  version` fix, linker path-order fix for Android≥7, and a glibc-2.43 build
  fix. All post-date and are absent from Droidian's fork. This builds on the
  EXISTING trixie rootfs (glibc 2.41 fine; source build, no distro swap, no
  rootfs rebuild). Open q: satisfying Droidian's phoc/wlroots debs against a
  self-built libhybris (dpkg-provides/equivs, or build matching .debs).
- **Distro swap (Arch ARM / Alpine) — side research, noted, NOT recommended
  for the wall.** The wall is libhybris source, so no distro bypasses it.
  Alpine = **musl**, which contradicts the patcher's whole glibc premise —
  strictly worse. Arch ARM = rolling **glibc 2.43** (fine) but loses every
  Droidian prebuilt (phoc, wlroots, adaptation configs) and still needs an
  upstream-libhybris source build — no advantage over doing that on Debian.

Until libhybris renders, desktop-on stops SF and leaves the panel dark
(recover via `./dos shell /data/decemberos/bin/desktop-off`).

Android-side of §4 stays proven (2026-07-03 19:05 toggle round trip: 13
input devices grabbed, SF stopped, clean restore). Only the guest-side
(compositor takeover) is blocked, now specifically on libhybris.

NOTE: the running guest's apt state (gdb, linkerconfig, the z4 downgrade,
libtls-padding0) and the runtime mounts/iptables/ip-rules do NOT persist a
reboot — persistence is via `toggle/guest-start` + the on-device rootfs on
`/data`, which does persist. A clean rebuild should go through
`guest/setup-guest.sh`.
