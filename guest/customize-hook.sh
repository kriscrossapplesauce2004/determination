#!/bin/sh
# mmdebstrap customize hook: Droidian repo (libhybris + hwcomposer backends),
# guest user, and the hybris environment. $1 = rootfs dir.
#
# When the rootfs is built via the debootstrap-on-device path instead
# (build-rootfs.sh fallback), guest/setup-guest.sh applies these same
# steps over adb — keep the two in sync.

set -eu
R="$1"

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
export EGL_PLATFORM=hwcomposer
export HYBRIS_EGLPLATFORM=hwcomposer
export ANDROID_ROOT=/system
export HYBRIS_LD_LIBRARY_PATH=/usr/lib/android:/vendor/lib64:/system/lib64:/odm/lib64:/apex/com.android.runtime/lib64/bionic
EOF
# /product and /system_ext are symlinks into /system on Android.
ln -sf /system/product "$R/product" || true
ln -sf /system/system_ext "$R/system_ext" || true

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
