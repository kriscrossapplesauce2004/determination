#!/bin/sh
# mmdebstrap customize hook: Droidian repo (libhybris + hwcomposer backends),
# guest user, and the hybris environment. $1 = rootfs dir.

set -eu
R="$1"

# Droidian repo for libhybris, libhybris-utils (test_hwcomposer), and the
# wlroots hwcomposer backend packages. Keyring fetched at build time.
mkdir -p "$R/etc/apt/sources.list.d" "$R/usr/share/keyrings"
wget -qO "$R/usr/share/keyrings/droidian.gpg" \
    https://repositories.droidian.org/droidian.gpg || \
    echo "WARN: droidian keyring fetch failed; add manually before apt update"
cat > "$R/etc/apt/sources.list.d/droidian.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/droidian.gpg] https://repositories.droidian.org/apt/production trixie main
EOF

# Hybris: bionic linker namespace needs the vendor paths that lxc bind-mounts.
cat > "$R/etc/profile.d/hybris.sh" <<'EOF'
export EGL_PLATFORM=hwcomposer
export HYBRIS_EGLPLATFORM=hwcomposer
# Android property area, bind-mounted from the host (see guest/lxc/config)
export ANDROID_ROOT=/android/system
EOF

# Guest user matching the phone owner.
chroot "$R" useradd -m -G video,input,render -s /bin/bash melissa || true
echo 'melissa ALL=(ALL) NOPASSWD: ALL' > "$R/etc/sudoers.d/melissa"

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
