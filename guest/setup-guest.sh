#!/system/bin/sh
# Determination guest customization — runs ON THE PHONE as root, against an
# already-extracted rootfs at /data/determination/guest (the debootstrap-on-
# device path). Mirror of guest/customize-hook.sh — keep the two in sync.
#
# Prereqs pushed to /data/local/tmp: droidian.gpg (fetch from
# https://raw.githubusercontent.com/droidian/droidian-archive-keyring/droidian/droidian/droidian.gpg
# — the packaged keyring debs are all stale; only git has the Jan/2025
# staging signing key).
set -e
G=/data/determination/guest
CH() { chroot "$G" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"; }

# Droidian staging repo (trixie suite) — key pushed alongside this script.
mkdir -p "$G/etc/apt/sources.list.d" "$G/usr/share/keyrings"
cp /data/local/tmp/droidian.gpg "$G/usr/share/keyrings/droidian.gpg"
chmod 644 "$G/usr/share/keyrings/droidian.gpg"
cat > "$G/etc/apt/sources.list.d/droidian.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/droidian.gpg] https://staging.repo.droidian.org/ trixie main
EOF

# Hybris environment. Android is bind-mounted at the real root paths (see
# guest/lxc/config), so libhybris' compiled defaults mostly just work; the
# one addition is the apex bionic dir, where libc.so actually lives on
# Android 10+ (it is NOT on the default /vendor:/system:/odm path).
cat > "$G/etc/profile.d/hybris.sh" <<'EOF'
# Default to the wayland EGL platform: ordinary processes are Wayland
# CLIENTS of phoc (GPU app buffers over android_wlegl). Only the
# compositor itself needs hwcomposer, and desktop-on / the smoke scripts
# export that explicitly.
export EGL_PLATFORM=wayland
export HYBRIS_EGLPLATFORM=wayland
export ANDROID_ROOT=/system
export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
EOF

# /product and /system_ext are symlinks into /system on Android; recreate
# them so vendor blobs that reference those roots resolve.
ln -sf /system/product "$G/product" 2>/dev/null || true
ln -sf /system/system_ext "$G/system_ext" 2>/dev/null || true

# Android device-node groups (recon 2026-07-12, artifacts/node-perms-probe.txt):
# the session runs as the unprivileged user melissa, NOT root. Almost every
# node it touches is already reachable — GPU/dri/binder/ashmem are world-rw and
# kgsl/ion are owned by uid/gid 1000 (== melissa == Android AID_SYSTEM). The
# ONLY gate is /dev/input/* (0660 root:1004, AID_INPUT): Debian's input group is
# gid 995 and does NOT match, so we create a group at Android's numeric gid and
# add melissa. seatd's socket is group video(44), which melissa already gets.
CH "getent group android_input   >/dev/null || groupadd -g 1004 android_input"
CH "getent group android_graphics >/dev/null || groupadd -g 1003 android_graphics"
CH "getent group android_audio    >/dev/null || groupadd -g 1005 android_audio"

# Guest user matching the phone owner. uid 1000 is load-bearing (owner of
# kgsl/ion); keep it pinned. usermod makes group membership idempotent whether
# or not the account already exists.
CH "id melissa >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash melissa"
CH "usermod -aG video,input,render,audio,android_input,android_graphics,android_audio melissa"

# Password-gated sudo (proper sudo, not NOPASSWD-ALL). No password is baked into
# the image — set one on-device with \`det passwd\` before sudo will work. Guest
# provisioning does not need it: setup-*.sh run as root via lxc-attach, not sudo.
mkdir -p "$G/etc/sudoers.d"
echo 'melissa ALL=(ALL) ALL' > "$G/etc/sudoers.d/melissa"
chmod 440 "$G/etc/sudoers.d/melissa"

# Hostname + hosts
echo determination > "$G/etc/hostname"
grep -q determination "$G/etc/hosts" 2>/dev/null || \
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tdetermination\n' > "$G/etc/hosts"

# veth network inside the guest (lxc config assigns the address too; this
# keeps it across systemd-networkd restarts)
mkdir -p "$G/etc/systemd/network"
cat > "$G/etc/systemd/network/eth0.network" <<'EOF'
[Match]
Name=eth0
[Network]
Address=192.168.117.2/24
Gateway=192.168.117.1
DNS=1.1.1.1
DNS=8.8.8.8
EOF
CH "systemctl enable systemd-networkd >/dev/null 2>&1 || true"

# Resolver: systemd-resolved is NOT running, so /etc/resolv.conf is a plain
# static file (networkd's DNS= above is a no-op until resolved ever runs).
# Two nameservers + short timeout so one dead/blocked resolver doesn't hang
# lookups; desktop-mode netd thrash makes single-resolver stalls real.
cat > "$G/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF

# Prefer IPv4: the guest is IPv4-NAT only (link-local v6, no default v6
# route) but resolvers happily return AAAA records — without this, every
# dual-stack client tries unreachable IPv6 first (2026-07-11).
grep -q '^precedence ::ffff:0:0/96 100' "$G/etc/gai.conf" 2>/dev/null ||
    echo 'precedence ::ffff:0:0/96  100' >> "$G/etc/gai.conf"

# Don't fight for ttys that don't exist / are Android's
CH "systemctl mask getty@tty1.service console-getty.service >/dev/null 2>&1 || true"

# Version pin: staging's newest libhybris needs libc6 > 2.42, trixie has
# 2.41 — the droidian0+z4 build is the newest that installs on trixie.
# Pin the whole family or apt's solver mixes versions and fails.
mkdir -p "$G/etc/apt/preferences.d"
printf 'Package: *\nPin: version *z4+git20250520205628*\nPin-Priority: 1001\n' \
    > "$G/etc/apt/preferences.d/libhybris-z4"

# First-boot script: libhybris + the gating smoke test.
cat > "$G/root/firstboot.sh" <<'EOF'
#!/bin/sh
apt update
apt install -y libhybris libhybris-utils
# Smoke test (spec §3): must render before anything else is attempted.
test_hwcomposer
EOF
chmod +x "$G/root/firstboot.sh"

echo "guest customization complete"
