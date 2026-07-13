# North star

Where Determination is headed, now that the core is proven (milestones 1–4
and 6 done, verified on device 2026-07-11). Ordered roughly by
priority; strike items as they land and keep this file honest.

## The big one: make it universal

Everything so far is hand-fitted to one phone (guacamoleb / SM8150 /
Adreno 640 / crDroid 12.11). The long-term goal is that Determination is a
*method* any Android device can adopt, not a guacamoleb artifact. That
means, roughly:

- **Recon-driven configuration**: `recon/` already probes composer HAL,
  gralloc, binderfs, kernel config. Grow it into a generator — recon output
  should *produce* the kernel fragment checklist, LXC bind list, and
  libhybris env instead of a human reading findings and editing scripts.
- **Factor the device-specifics out of the scripts**: panel resolution/dpi
  (phoc.ini), backlight node, brightness quirk, battery gauge node, notch
  panel JSON, input quirks, boot partition names — collect them into one
  per-device profile the toggles and setup scripts read.
- **Catalog the quirks by class, not device**: the Adreno struct-varying
  shader rewrite, the SDM brightness-0 dim, the pidfd half-backport shim,
  the ashmem per-boot node — each is really a *family* quirk (GPU blob
  generation, display driver, kernel version). Document which axis each
  belongs to so the next device knows what to test.
- **Upstream what's upstreamable**: the libhybris patches (locale/`*_l`
  hooks, `HWCNativeWindowSetBufferCount`, brightness call, GSK shader fix
  as opt-in) belong in libhybris/libhybris, not just our build script.
- **Kernel fragment portability**: `determination.config` is already mostly
  generic (namespaces, cgroups, binderfs). Keep it that way; device trees
  and drivers stay per-device.

## Bugs / hardening (near-term)

1. **Power-button wake path** — phoc's hwcomposer output re-enable never
   fires after a blank; button is quirked inert and idle-blank forced to 0.
   The one thing that still makes a session fragile for a human. Fix next.
2. **Pstore in kernel #4** — CONFIG_PSTORE + PSTORE_RAM/RAMOOPS so the next
   panic leaves evidence. Small config change, rebuild, reflash.
3. **Guest DNS flakiness** — re-test first: likely a symptom of the netd
   flushing that the milestone-6 Zygisk hook just eliminated.
4. **Rebuild lxc/bin** (`guest/build-lxc.sh`) to drop the baked-in
   `/data/decemberos` runtime path; then remove the compat symlink from
   guest-start.
5. **QS tile tap-test** — registration/binding already confirmed; one tap
   whenever convenient closes it.
6. **Desktop-mode soak test** — milestone 6 removed the framework thrash
   that correlated with the 07-06 reboots/panic; a long session on wall
   power would confirm the stability story cheaply.

## Features

7. **Audio (pipewire) in the guest** — gives volume keys meaning; the
   prerequisite for calls-less phone basics.
8. **Phosh polish** — feedbackd (haptics), backgrounds, session niceties.

## Milestone 5: external convergence (the last milestone)

9. Architecture pinned 2026-07-13 (plan + tasks #1–#4; no nested-under-phoc
   — melissa's call). Two chained phases on the **minigbm/native-DRM track**:

   **Exclusive first:** downstream SDE is a real atomic KMS driver
   (`msm_drm` on card0 — 5 CRTCs, 16 planes, dumb buffers, PRIME, DSI + DP
   + writeback connectors; `artifacts/kms-probe-20260713.txt`). Stack: Mesa
   Turnip-KGSL + zink (`guest/build-mesa.sh`, `/opt/mesa`) + minigbm msm
   backend as libgbm (`guest/build-minigbm.sh`, `/opt/minigbm`) + the
   compositor's native DRM backend. The vendor composer HAL is just another
   DRM client — stop it (plus SF) and the guest owns KMS. Gates:
   `guest/native-smoke.sh` (no display risk — **PASSED 2026-07-13**), then a
   `modetest -s` dumb-buffer commit on DSI (the go/no-go —
   **PASSED 2026-07-13**, `toggle/native-kms-gate`, bars on panel with
   brightness control; atomic + flip-event delivery still to verify). Payoff: vendor GL exits the
   guest (Adreno varying hack, android_wlegl all retire) and unmodified
   desktops return — phoc native, then **KWin** (NoopSession first, elogind
   if needed). GNOME/Mutter deferred (logind-hard; phosh IS GNOME).
   phosh-on-monitor already works today via the hwc backend, plug-and-play —
   the gap this fixes is a desktop-grade DE, not the hardware path.

   **Then concurrent (the headline):** SF alive on the panel; guest renders
   headless on the same Mesa stack; minigbm dmabuf ⇄ AHardwareBuffer bridge
   (same UBWC layouts as gralloc — that's the whole trick) into an Android
   presenter on the DP display; input back via uinput; summon UX = the
   presenter's show/hide. True concurrency is ONLY reachable this way on
   4.14: one DRM master per card, no DRM leases, single composer client.

## Standing discipline

- Full desktop-off regression after every session.
- Evidence into `artifacts/` with descriptive names; structured recon into
  `recon/report-*/`.
