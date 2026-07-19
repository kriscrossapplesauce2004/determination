# Determination Zygisk module — milestone 6

Runtime hooks inside `system_server` via Zygisk (Magisk 30.7, API v5).

## Hooks

1. **SF-death handler suppression** (IMPLEMENTED — `jni/main.cpp`):
   PLT-hooks `__system_property_set` in system_server's loaded libraries.
   Swallows `ctl.start`/`ctl.restart` for `surfaceflinger` while
   `/data/determination/run/desktop-mode` exists. Zero-latency in-process
   replacement for the shell suppressor loop (which remains as a fallback +
   backlight keeper in `toggle/desktop-on`).
2. **Desktop-mode / freeform enables** — WMS + DisplayManager hooks, only for
   behaviours with no `resetprop`-flippable flag (flags are handled in
   `magisk-module/post-fs-data.sh`).
3. **Summon UX** — QS tile / gesture in SystemUI wired to
   `/data/determination/bin/desktop-on|off`, as a hook, not a replaced APK.
4. **Companion root bridge** — the module stays loaded only in the Determination
   app process and exposes a same-UID abstract Unix socket. Fixed commands are
   relayed through Zygisk's root companion process; `enter`/`exit` therefore do
   not spawn `su` or expose an exported root command surface. Older modules
   degrade to the app's existing `su` path.

## Build

Requires Android NDK. From the `zygisk/` directory:

    ndk-build NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=jni/Android.mk

Output: `libs/arm64-v8a/libdetermination.so` — packaged into the Magisk
module zip as `zygisk/arm64-v8a.so` by `magisk-module/build-module.sh`.

## Architecture

Boundary (spec §2): Zygisk reaches zygote-forked processes only.
SurfaceFlinger is native and unhookable from here — by design we stop it,
never patch it. The hook intercepts the RESTART REQUEST, not SF itself.

For app processes, the module calls `setOption(DLCLOSE_MODULE_LIBRARY)` to
unload immediately — we only care about system_server.
