#!/bin/sh
# mmdebstrap customize hook: Droidian repo (libhybris + hwcomposer backends),
# guest user, and the hybris environment. $1 = rootfs dir.
#
# When the rootfs is built via the debootstrap-on-device path instead
# (build-rootfs.sh fallback), guest/setup-guest.sh applies these same
# steps over adb — keep the two in sync.

set -eu
R="$1"
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

# Droidian repo for libhybris, libhybris-utils (test_hwcomposer), their
# patched wlroots and phoc. 2026-07: repositories.droidian.org is dead;
# the staging repo carries a trixie suite and is current. The staging repo
# signs with a Jan/2025 key that is NOT in any published
# droidian-archive-keyring deb (they're all stale) — fetch the keyring
# straight from their git, which does carry it.
mkdir -p "$R/etc/apt/sources.list.d" "$R/usr/share/keyrings"
wget -qO "$R/usr/share/keyrings/droidian.gpg" \
    "https://raw.githubusercontent.com/droidian/droidian-archive-keyring/droidian/droidian/droidian.gpg" \
    || echo "WARN: droidian keyring fetch failed; add manually before apt update"
chmod 644 "$R/usr/share/keyrings/droidian.gpg"
cat > "$R/etc/apt/sources.list.d/droidian.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/droidian.gpg] https://staging.repo.droidian.org/ trixie main
EOF

# Staging's newest libhybris needs libc6 > 2.42; trixie has 2.41. The
# droidian0+z4 build is the newest that installs — pin the whole family
# or apt's solver mixes versions and fails.
mkdir -p "$R/etc/apt/preferences.d"
printf 'Package: *\nPin: version *z4+git20250520205628*\nPin-Priority: 1001\n' \
    > "$R/etc/apt/preferences.d/libhybris-z4"

# Hybris: bionic linker namespace needs the vendor paths that lxc bind-mounts
# at the real root. libc.so lives in the apex on Android 10+, which is not on
# libhybris' default search path — add it explicitly.
cat > "$R/etc/profile.d/hybris.sh" <<'EOF'
# Default to the wayland EGL platform: ordinary processes are Wayland
# CLIENTS of phoc (GPU app buffers over android_wlegl). Only the
# compositor itself needs hwcomposer, and desktop-on / the smoke scripts
# export that explicitly.
export EGL_PLATFORM=wayland
export HYBRIS_EGLPLATFORM=wayland
export ANDROID_ROOT=/system
export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
EOF
# /product and /system_ext are symlinks into /system on Android.
ln -sf /system/product "$R/product" || true
ln -sf /system/system_ext "$R/system_ext" || true

# Resolver: no systemd-resolved in the guest — static resolv.conf, two
# nameservers + short timeouts. Prefer IPv4 in gai.conf: the guest is
# IPv4-NAT only but gets AAAA answers (see setup-guest.sh, keep in sync).
cat > "$R/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
echo 'precedence ::ffff:0:0/96  100' >> "$R/etc/gai.conf"

# Android device-node groups (recon 2026-07-12, artifacts/node-perms-probe.txt):
# the session runs as the unprivileged user melissa, NOT root. GPU/dri/binder/
# ashmem are world-rw and kgsl/ion are owned by uid/gid 1000 (== melissa ==
# Android AID_SYSTEM); the ONLY node that gates a non-root compositor is
# /dev/input/* (0660 root:1004, AID_INPUT). Debian's input group (gid 995) does
# not match, so make a group at Android's numeric gid. seatd's socket is group
# video(44), which melissa already gets.
chroot "$R" sh -c 'getent group android_input   >/dev/null || groupadd -g 1004 android_input'
chroot "$R" sh -c 'getent group android_graphics >/dev/null || groupadd -g 1003 android_graphics'
chroot "$R" sh -c 'getent group android_audio    >/dev/null || groupadd -g 1005 android_audio'

# Guest user matching the phone owner. uid 1000 is load-bearing (owner of
# kgsl/ion). usermod makes membership idempotent whether or not melissa exists.
chroot "$R" sh -c 'id melissa >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash melissa'
chroot "$R" usermod -aG video,input,render,audio,android_input,android_graphics,android_audio melissa

# Password-gated sudo (proper sudo, not NOPASSWD-ALL). No password is baked into
# the image — set one on-device with `det passwd` before sudo will work.
echo 'melissa ALL=(ALL) ALL' > "$R/etc/sudoers.d/melissa"
chmod 440 "$R/etc/sudoers.d/melissa"

# The libhybris packages themselves install on first boot of the guest (needs
# the device's vendor blobs visible to configure linker namespaces sanely):
cat > "$R/root/firstboot.sh" <<'EOF'
#!/bin/sh
apt update
apt install -y libhybris libhybris-utils
# Smoke test (spec §3): must render before anything else is attempted.
test_hwcomposer
EOF
chmod +x "$R/root/firstboot.sh"

# Direct audio is dormant until the host ownership journal publishes its claim.
install -d "$R/usr/local/bin"
install -m 0755 "$HERE/det-audio-session" "$R/usr/local/bin/det-audio-session"
install -m 0755 "$HERE/setup-audio.sh" "$R/root/setup-audio.sh"
chroot "$R" /root/setup-audio.sh --configure-only
