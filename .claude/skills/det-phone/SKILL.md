---
name: det-phone
description: >-
  Talk to melissa's OnePlus 7 (guacamoleb) running Determination. Use whenever
  a task needs adb/su/root shell on the phone, dropping files into the LXC
  guest, running desktop-on/desktop-off, wireless-adb reconnect, or the `det`
  helper. Encodes the adb/su/lxc QUOTING rule that caused every past "mystery
  permission denied", the never-`adb root` rule, and the guest file-drop
  procedure. Triggers: phone, device, OnePlus 7, adb, su, Magisk, guest shell,
  lxc-attach, push file to phone, desktop mode.
---

# Talking to the phone (Determination / OnePlus 7 `guacamoleb`)

Run everything through the **`det`** helper in `~/decemberos` — it hides the
wireless-adb dance, uses the right platform-tools, and never drops root the
wrong way. `det` subcommands: `find`, `connect`, `shell [cmd…]`, `status`,
`recon`, `push-module`, `publish`.

```
det status                 # connection, root, kernel, phone/desktop mode, module
det shell 'cmd; cmd2'      # ROOT shell (Magisk su), whole chain in one arg
det connect                # discover + connect over wireless adb
```

## Hard rules (violating these is how past sessions lost hours)

- **The quoting rule — the #1 cause of "mystery denials."** Root must be one
  quoted chain: `adb shell "su -c '<all cmds>'"`. If you split it, only the
  FIRST command runs as root and the rest silently run unprivileged. `det
  shell 'a; b; c'` already does this — prefer it over raw adb.
- **Never `adb root`.** It drops the wireless transports. Root is `su` via
  Magisk only (`det shell …` / `adb shell su -c …`).
- **Silent "Permission denied" from `su`** = Magisk's Superuser → Shell toggle
  is OFF. Ask melissa to flip it; the **screen must be unlocked** for the grant
  prompt. Don't chain workarounds — ping her (see `[[ping-dont-flail]]`).
- Official **platform-tools only** (`~/platform-tools`). Distro `android-tools`
  adb has broken pairing. Wireless-adb port rotates every reboot — rediscover
  with `det find` (`adb mdns services`). A USB cable is also connected now, so
  fastboot rescue exists; a kernel bootloop is no longer a dead phone.

## The LXC guest (Debian trixie, name `determination`)

- Guest shell: `det shell lxc-attach -n determination -- <cmd>` (confirm the
  container name with `det shell lxc-ls` if unsure).
- **File drop into the guest** (adb can't write guest rootfs paths directly):
  1. `adb push <file> /sdcard/Download/…`
  2. `su cp` it over an **existing** file inside the guest rootfs on `/data`
  3. `lxc-attach … /bin/cp` to the final name — **direct exec, no inner
     shell** (an inner shell re-triggers the quoting trap).
- **Install a package in the guest** when its network is flaky: download the
  `.deb` on the host → `adb push` → `dpkg -i` inside the guest.

## Phone ⇄ desktop mode

- `det shell /data/determination/bin/desktop-on` — stops SurfaceFlinger, hands
  the panel to the guest compositor.
- `det shell /data/determination/bin/desktop-off` — **always** restores SF.
  Run this and a full round-trip regression at the end of every session.
- **Wedged/blanked session:** `pkill phoc` in the guest — the desktop-on
  supervisor relaunches everything (input grabs included) in ~10s.
- **Guest networking is only reliable in PHONE mode.** In desktop mode
  `system_server` crash-loops and thrashes netd/WiFi (the Milestone-6 Zygisk
  hook is the real fix). Do network-heavy guest work in phone mode; see
  `[[det-guest]]` for the debugging playbook.

Probe/script outputs go to `artifacts/` with descriptive names (standing
request — `[[save-script-outputs-to-artifacts]]`).
