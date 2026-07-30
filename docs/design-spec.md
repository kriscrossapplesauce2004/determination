# Android Convergence Layer : Design Specification

Modernised Maru-topology convergence: Android stays PID1 and fully live; a glibc
Wayland desktop runs as an LXC guest on the **same downstream vendor kernel**;
`libhybris` bridges the guest to the bionic GPU/display blobs. Supports both
external-display convergence (concurrent) and internal-panel-on-demand desktop
mode (time-sliced). Shipped as a custom `boot.img` (custom kernel + Magisk-patched
ramdisk) plus Zygisk : not a ROM.

**Target:** OnePlus 7 `guacamoleb` : SM8150 / Adreno 640 (a6xx).

---

## 1. Topology decision (the thing everything hangs off)

There are two established inversions of "Linux + Android on one kernel," and we are
deliberately choosing the harder one because it's the only one that keeps a live
phone:

- **Halium / Droidian / UT topology:** GNU/Linux is PID1 (systemd, glibc); Android
  runs *headless* in an LXC container purely to host the blobs. The Linux
  compositor owns `hwcomposer` from boot : **no display arbitration, ever.**
  Android's UI never exists.
- **Maru topology (ours):** Android init is PID1; the phone is fully live; the
  glibc desktop runs in an LXC container *on top*. `hwcomposer` is owned by
  SurfaceFlinger, and the guest compositor can only have the display **after SF
  releases it.**

We take the Maru topology because "keep SystemUI and a real phone" is a hard
requirement, not a nice-to-have. The cost is that **display/input arbitration is
now our problem** : Halium/Droidian never solve it because they never have to.
Our genuinely novel delta over both prior-art families is **internal-panel
on-demand handoff on a live Android**; neither Maru (external-only) nor Droidian
(headless Android) ships it.

Implication chain, stated once: one kernel → no kexec, no dual driver copies;
`libhybris` means guest and host share the *same* bionic blob; the guest container
must have the Android `/dev` (binder, `kgsl`, `ion`/dmabuf), the property area, and
`/vendor` libs visible in its namespace.

---

## 2. Packaging: custom boot.img + Zygisk

`boot.img` carries both kernel and ramdisk. We patch the **kernel** (container
enables + any driver patches); Magisk patches the **ramdisk** (init hijack, root,
boot scripts). `/system` and `/vendor` remain stock. Rebuild-and-repack, not
build-a-userland-forever.

| Layer | Mechanism | Role |
|---|---|---|
| Custom kernel (boot.img) | kconfig + patches | user namespaces, cgroup v2 delegation, `CONFIG_ANDROID_BINDERFS`/binder, `memfd`/ashmem, whatever the LXC guest + libhybris need. This is the *only* place kernel gaps get fixed : Magisk can't. |
| Magisk ramdisk patch | init hijack | persistent root, `post-fs-data` / `service.d` boot hooks, container launch |
| `resetprop` | prop control | mask/override `ctl.*`, `init.svc.*`, gate SF/service restart triggers, flip hidden AOSP desktop/freeform flags without recompiling framework |
| `magiskpolicy` | live sepolicy | targeted allow-rules during bring-up instead of rebuilding sepolicy; harden into a real policy module later |
| Zygisk (+ LSPosed) | zygote injection | runs inside `system_server` → WMS/DisplayManager/desktop-mode changes as **method hooks** (signature-bound, degrade gracefully; not ABI-brittle like overlaid `services.jar`) |

**Zygisk boundary, precisely:** it reaches the zygote-forked managed world
(`system_server`, apps). It does **not** reach init-started native daemons.
SurfaceFlinger is native and never forked from zygote, so it's unhookable by
Zygisk : irrelevant to us because we **stop** SF, never patch its code. Any need
for SF *code* changes would drop you into `LD_PRELOAD`/recompile territory; the
design avoids ever needing that.

---

## 3. Guest + display acquisition

Guest: Debian glibc rootfs in LXC, sharing the kernel, with `libhybris` and the
`/vendor` blob paths bind-mounted in. Vendor EGL/GLES through libhybris is the
product GPU interface across device families. Native Mesa drivers are optional
diagnostics and optimisations, never the compatibility baseline.

The proven compositor binds the display through **libhybris → hwcomposer HAL**.
For compositors whose modern backends require GBM, the target is Android
gralloc allocation plus a minigbm-facing GBM facade. Minigbm provides the Linux
buffer API; it does not replace vendor EGL or choose the GPU driver. The full
gralloc native handle and synchronization fences are part of the buffer
contract. See `docs/graphics-architecture.md`.

The composer HAL is **single-client** (whether HIDL `graphics.composer@2.x` or
AIDL `composer3`, depending on your Halium base's Android level). SF holds that
client at runtime; the guest compositor cannot bind it until SF releases it. This
is *why* the toggle in §4 exists : it's not a nicety, it's the arbitration
protocol for a single-client HAL. Gralloc/mapper version (gralloc0/1 + mapper 2.x
vs gralloc4 + mapper 4.0) must match what the libhybris backend expects; verify
against the actual `guacamoleb` vendor image, not assumptions.

**Compositor support is per-backend-family, not per-compositor:**

| Backend integration | Unlocks |
|---|---|
| wlroots ↔ hwcomposer | Hyprland, sway, Phosh : the whole wlroots clan, one integration |
| KWin ↔ Android-backed GBM/EGL winsys | KDE Plasma / Plasma Mobile : in development; libhybris vendor rendering plus minigbm API |

wlroots first (best compositor-per-effort ratio). KWin is a distinct second
integration, not a variant of the first.

The libhybris vendor path is deliberately GPU-family-neutral: Adreno, Mali,
PowerVR and other Android-supported GPUs keep their shipped blobs. Smoke-test
vendor EGL, gralloc and hwcomposer independently before enabling a compositor.
The native Turnip/KGSL result on guacamoleb is retained as evidence and a
performance experiment, not used to classify other devices as supported.

---

## 4. Internal-on-demand handoff (the core work)

Single physical surface, single-client HAL, live Android on the other side of it.
The handoff is a mode toggle, not concurrency.

**Display, phone → desktop:**
1. `stop surfaceflinger` (`ctl.stop`). Confirm it releases the composer client and
   the GPU context.
2. Suppress re-`start`. An explicit init `stop` is honoured, but several things
   re-issue `start surfaceflinger`: `system_server`/DisplayManager's SF-death
   handling, `bootanim`, and any `class_restart`. Mask those triggers
   (service overrides + `resetprop` on the relevant `init.svc`/`ctl` props). The
   respawn fight is the real engineering here, not the stop itself.
3. Guest compositor binds hwcomposer, drives the panel.

**Desktop → phone:** guest releases the composer client cleanly; `start
surfaceflinger`; verify the panel re-inits without a dead/black transition.

Stress the cycle for wedge and GPU-context/fd leaks under repeated flips : a
single clean toggle proves nothing; repeated cycling is where the HAL state
machine and fd ownership bugs surface.

**Input (correction to the naïve model):** on modern Android there is **no
standalone `inputflinger` process** : input is `EventHub`/`InputReader` inside
`system_server`, opening `/dev/input/event*` non-exclusively. So you can't "stop
inputflinger." The real handoff is exclusive-grab arbitration: have the guest's
libinput take `EVIOCGRAB` on the evdev nodes for desktop mode (blocking Android's
readers), release on exit. Without a grab you get **double input** delivered to
both stacks. Decide grab-vs-suspend early; grab is the lower-risk path since it
doesn't require reaching into `system_server`.

**SELinux:** stopping SF and grabbing evdev from a new domain trips a wall of
denials. Iterate with `magiskpolicy`; consolidate into a policy module before
release.

---

## 5. External convergence (concurrent presenter)

SurfaceFlinger must remain the sole composer client while Android stays live, so
the guest cannot concurrently acquire hwcomposer merely because DP is a second
surface. The guest renders into Android-gralloc buffers with vendor EGL through
libhybris; an Android-side presenter imports those buffers and places them on
the external display. Input returns through uinput. Native DRM leases are not
available on the proven 4.14 kernel.

The portable direction is Android-owned allocation. A device-proven reverse
import from minigbm allocation may remove overhead, but never replaces the
gralloc/native-handle compatibility path.

| | External (§5) | Internal on-demand (§4) |
|---|---|---|
| SystemUI / phone | live | time-sliced off |
| Surfaces | two, independent | one, arbitrated |
| SF | running | stopped + respawn-masked |
| Input | untouched | EVIOCGRAB handoff |
| Difficulty | buffer transport + presenter | display-owner arbitration |

---

## 6. Framework / UX (Zygisk + LSPosed hooks)

All Android-side behaviour changes are runtime hooks in `system_server`, no
framework recompile:

- Desktop-mode / freeform / multi-window: hook WMS + DisplayManager; the cheapest
  tweaks are `resetprop` dev-flag flips first, hooks only where a flag doesn't
  exist.
- Summon trigger: a real SystemUI affordance (QS tile / gesture) wired to the
  mode switch, implemented as a hook : not a bind-mounted replacement APK.
- Compositor selection: user-swappable across the two §3 backend families.

---

## 7. Milestones (risk-ordered, collapsed)

1. **Base + guest bring-up.** Custom kernel with container enables; Halium-style
   `/dev`, property, `/vendor` exposure into an LXC glibc guest; libhybris
   composer/EGL smoke test passes on `guacamoleb`.
2. **wlroots on the panel.** One wlroots compositor binding hwcomposer via
   libhybris.
3. **The toggle (§4).** SF stop + respawn-mask + composer handoff + EVIOCGRAB
   input handoff; stable across repeated cycling.
4. **External convergence (§5).** Concurrent internal-phone + external-desktop.
5. **KWin backend + compositor picker.**
6. **Summon UX + WMS/desktop-mode hooks (§6).**
7. **Portability manifest (last, deliberately).** Abstract blob set / kernel
   fragment / hwcomposer + gralloc quirks into a per-device config, derived from
   the working `guacamoleb` port rather than designed ahead of it.

---

## 8. Portability

The Android-side apparatus (boot.img + Zygisk) is fixed-cost and travels to any
rootable, custom-boot.img-capable device essentially free. The **libhybris
guest-acquisition layer is linear per SoC family** : a new SoC needs a hands-on
port pass (composer HAL version, gralloc/mapper, blob quirks), which is how
Halium/Droidian scaled and is not a restart. "Easy to build for other phones" is
accurate with the asterisk landing *only* on that layer, cleanly portable across
the well-blob'd Qualcomm set, hands-on beyond it.

---

## 9. Device recon (run with root on guacamoleb)

```sh
# Composer HAL flavour + version (HIDL 2.x vs AIDL composer3) and gralloc
adb shell 'ls -la /vendor/lib64/hw/ | grep -Ei "composer|gralloc|mapper|memtrack"'
adb shell 'lshal 2>/dev/null | grep -Ei "composer|graphics.mapper|allocator"'
adb shell dumpsys SurfaceFlinger | head -n 40

# GPU + dmabuf/ion nodes libhybris will drive
adb shell 'ls -la /dev/kgsl-3d0 /dev/ion /dev/dma_heap/ /dev/dri/ 2>/dev/null'

# Vendor/HAL fingerprints; who currently holds display/input
adb shell getprop | grep -Ei 'composer|gralloc|vndk|ro.hardware|vendor.sku'
adb shell 'lsof 2>/dev/null | grep -Ei "kgsl|/dev/dri|event[0-9]"'
```

The goal is to determine whether an existing SM8150/845-family libhybris port
drops in against these blobs or needs a modification pass.

---

## 10. Prior art

- **Droidian** : maintained Debian/Halium descendant; its wlroots↔hwcomposer
  plumbing is milestones 1–2. Diverges from us at the topology (it's headless
  Android) and has nothing on the §4 toggle.
- **Maru OS** : our topology exactly (Android PID1, Debian LXC guest), but
  external-only; no internal on-demand.
- **Halium** : the libhybris/container abstraction; note it inverts PID1 relative
  to us.
- **Ubuntu Touch / Sailfish** : production libhybris+Wayland; reference for the
  graphics handoff.
- **Waydroid** : inverse polarity (Android-in-container on a Linux host); useful
  plumbing reference.

---

## 11. Risk register

| Risk | Severity | Where handled |
|---|---|---|
| SF respawn re-grabs composer mid-handoff | high | §4 step 2 : trigger masking |
| Double input / no clean evdev handoff | high | §4 : EVIOCGRAB, decided early |
| Gralloc/mapper version mismatch vs libhybris backend | medium | §3 / §9 : verify against real vendor image |
| Composer client not released cleanly by SF | medium | §4 : cycle-stress for leaks |
| DP-alt enumeration quirks | medium | §5 : device-specific |
| Kernel missing container/binder enables | low–med | §2 : custom kernel, not blockable by Magisk |
| libhybris port work per new SoC | linear cost | §8 : expected, not a restart |
| Portability layer built before working port | self-inflicted | milestone 7 is last |
