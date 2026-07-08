#!/system/bin/sh
# One-shot on-device migration: DecemberOS -> Determination.
# Moves the persistent payload and disables the old Magisk module WITHOUT
# rebuilding the (expensive) Debian rootfs. Run once, as root, in PHONE mode.
#
#   det migrate            (pushes + runs this over adb), or
#   adb push migrate-to-determination.sh /sdcard/Download/ &&
#     adb shell "su -c 'sh /sdcard/Download/migrate-to-determination.sh'"
#
# After it succeeds: install the new (id=determination) module zip and reboot.
# The new module lays down the renamed bin/ scripts + boot hooks and refreshes
# lxc/config; guest-start rewrites guest/config from it on next start.

set -u
OLD=/data/decemberos
NEW=/data/determination
MODOLD=/data/adb/modules/decemberos

say() { echo "[migrate] $*"; }
die() { echo "[migrate] ABORT: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root (su -c)"

# --- Preconditions -----------------------------------------------------------
if [ -d "$NEW" ] && [ ! -d "$OLD" ]; then
    say "already migrated ($NEW exists, $OLD gone) — nothing to do"; exit 0
fi
[ -d "$OLD" ] || die "$OLD not found — nothing to migrate"
[ -e "$NEW" ] && die "$NEW already exists but $OLD does too — resolve by hand"

# Never migrate mid-handoff: desktop mode has live grabs, a stopped SF, and a
# running compositor bound to the composer HAL. Return to phone mode first.
if [ -f "$OLD/run/desktop-mode" ]; then
    die "in desktop mode — run $OLD/bin/desktop-off first, then re-run migrate"
fi

# --- Quiesce -----------------------------------------------------------------
# Stop the keeper loops and the container using the OLD tree's tools.
if [ -f "$OLD/run/net-keeper.pid" ]; then
    kill "$(cat "$OLD/run/net-keeper.pid" 2>/dev/null)" 2>/dev/null
fi
if [ -x "$OLD/lxc/bin/lxc-info" ] && \
   "$OLD/lxc/bin/lxc-info" -P "$OLD" -n guest 2>/dev/null | grep -q RUNNING; then
    say "stopping guest container"
    "$OLD/lxc/bin/lxc-stop" -P "$OLD" -n guest -t 15 2>/dev/null || \
        "$OLD/lxc/bin/lxc-stop" -P "$OLD" -n guest -k 2>/dev/null
    i=0
    while "$OLD/lxc/bin/lxc-info" -P "$OLD" -n guest 2>/dev/null | grep -q RUNNING; do
        i=$((i+1)); [ $i -gt 20 ] && die "guest would not stop — retry later"; sleep 0.5
    done
fi
# Drop the self-bind on $OLD/guest (guest-start's dev,exec,suid remount) so the
# rename isn't blocked by a busy mountpoint. Harmless if it wasn't mounted.
umount "$OLD/guest" 2>/dev/null

# --- Move the payload (same filesystem => fast rename, rootfs preserved) ------
say "moving $OLD -> $NEW"
mv "$OLD" "$NEW" || die "mv failed (guest still busy? mounts left?)"

# --- Rename guest-side dos-* artifacts to det-* -------------------------------
# The new host toggles look for det-input-udevdb / det-pidfd-shim.so by path.
# Rename in place so input + the pidfd shim keep working before any re-setup.
# (Belt-and-suspenders: re-running guest/setup-input.sh regenerates them too.)
find "$NEW/guest" -depth -name 'dos-*' 2>/dev/null | while read -r p; do
    d=$(dirname "$p"); b=$(basename "$p")
    nb="det-${b#dos-}"
    [ -e "$d/$nb" ] || { mv "$p" "$d/$nb" && say "renamed guest: $b -> $nb"; }
done

# --- Disable the old Magisk module -------------------------------------------
# Its service.sh/post-fs-data point at the now-gone $OLD. Flag it for removal
# so Magisk unmounts it cleanly on next boot; the new module replaces it.
if [ -d "$MODOLD" ]; then
    touch "$MODOLD/remove" "$MODOLD/disable" 2>/dev/null
    say "old module flagged for removal on next boot"
fi

# stale run/ state under the new path (loops from the old boot are dead)
rm -rf "$NEW/run"; mkdir -p "$NEW/run" "$NEW/log"

say "payload migrated to $NEW"
say "NEXT: install the new determination-magisk-*.zip (Magisk app or 'det push-module'),"
say "      then REBOOT. Recommended after reboot (phone mode): re-run"
say "      guest/setup-input.sh + setup-controls.sh to regenerate guest bits."
