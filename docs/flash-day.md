# Flash day checklist

Everything below is already built and waiting (see repo root / `boot/`).
Hard prerequisite: **a USB cable** — fastboot has no wireless mode, and the
cable is also the rescue path.

## Already done (don't redo)

- [x] Kernel built from crDroid's exact tree + running config + our fragment
      (`kernel/out/arch/arm64/boot/Image.gz-dtb`, 3m13s build)
- [x] `boot/determination-boot.img` — real installed boot_b
      (`artifacts/boot_b-crdroid-12.10.img`) repacked with our kernel;
      kernel-inside verified as our build, cmdline preserved
- [x] Magisk module zip (`magisk-module/determination-magisk-*.zip`) with static
      aarch64 evgrab + toggle scripts payload
- [x] Host toolkit: `./det` helper, magiskboot + cross tools in `toolchain/`

## Sequence

1. **Backup**: anything irreplaceable off /data (EDL last-resort wipes data).
2. **Magisk-patch the boot image** (on the phone, no cable needed):
   `./det connect && adb push boot/determination-boot.img /sdcard/Download/`
   → Magisk app → Install → *Select and Patch a File* → pick it →
   pull back `/sdcard/Download/magisk_patched-*.img`.
3. **RAM-boot first — flash nothing**:
   `adb reboot bootloader && fastboot boot magisk_patched-*.img`
   - No boot in ~2 min → hold power 10s; phone comes back on the untouched
     flashed kernel. Zero harm done. Debug from `artifacts/` config diffs.
4. **Verify while RAM-booted** (`./det status` — wants: root ok, our uname,
   `pid-ns: YES`): plus spot-checks — wifi, cellular, screen rotation, camera,
   charging. 10 minutes of "is the phone still a phone."
5. **Only now flash**: `fastboot flash boot magisk_patched-*.img && fastboot reboot`
   (slot `_b` is active; `fastboot set_active a` + reboot is the undo if
   anything regresses later).
6. **Install the module**: `./det push-module`, reboot, `./det status` again.
7. Proceed to guest bring-up: `guest/build-rootfs.sh` (needs mmdebstrap on
   the host) + a static arm64 lxc for `/data/determination/lxc/bin`.

## If it goes wrong

| Symptom | Response |
|---|---|
| RAM-boot hangs | power-cycle; nothing was written; diff config, rebuild (fast, ~3 min) |
| Flashed + bootloop | `fastboot flash boot artifacts/boot_b-crdroid-12.10.img` (the exact dumped original) |
| fastboot unreachable | switch slot from recovery, or MSMDownloadTool/EDL (wipes data, unbrickable device) |
| Boots but phone flaky | compare `/proc/config.gz` vs `artifacts/kernel-config-full.txt` — the delta must be only our fragment |
