# Determination Zygisk module — milestone 6, deliberately last

Runtime hooks inside `system_server` (Zygisk + LSPosed). Nothing here blocks
milestones 1–4; the toggle ships with the shell suppressor loop first.

Planned hooks, in order of value:

1. **SF-death handler suppression** — replace the `desktop-on` suppressor loop:
   hook `system_server`'s SurfaceFlinger death-recipient / `ctl.restart`
   issuance so a stopped SF *stays* stopped while `/data/determination/run/desktop-mode`
   exists. This is the "real" fix for spec §4 step 2.
2. **Desktop-mode / freeform enables** — WMS + DisplayManager hooks, only for
   behaviours with no `resetprop`-flippable flag (flags are handled in
   `magisk-module/post-fs-data.sh`).
3. **Summon UX** — QS tile / gesture in SystemUI wired to
   `/data/determination/bin/desktop-on|off`, as a hook, not a replaced APK.

Boundary reminder (spec §2): Zygisk reaches zygote-forked processes only.
SurfaceFlinger is native and unhookable from here — by design we stop it,
never patch it.
