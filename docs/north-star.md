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

9. Guest compositor on a DP-alt external display *concurrently* with
   SurfaceFlinger on the panel; then KWin; then the summon UX. Hardware
   path already proven (Android's own desktop mode runs over DP-alt), so
   this is integration work, not risk.

## Standing discipline

- Full desktop-off regression after every session.
- Evidence into `artifacts/` with descriptive names; structured recon into
  `recon/report-*/`.
