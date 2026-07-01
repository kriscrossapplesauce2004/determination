#!/system/bin/sh
# Cycle-stress the §4 toggle: a single clean toggle proves nothing; repeated
# cycling is where the HAL state machine and fd-ownership bugs surface.
# Watches for wedge (SF not returning) and GPU-context/fd leaks.
# Usage: cycle-stress.sh [iterations]   (default 25)

set -u
DOS=/data/decemberos
N="${1:-25}"

fd_count() { ls "/proc/$(pidof "$1" | cut -d' ' -f1)/fd" 2>/dev/null | wc -l; }
composer_pid() { pidof vendor.qti.hardware.display.composer-service \
    || pidof android.hardware.graphics.composer@2.4-service \
    || pidof android.hardware.graphics.composer@2.3-service; }

BASE_FD=$(fd_count "$(composer_pid >/dev/null && echo composer)" 2>/dev/null)
echo "composer HAL pid=$(composer_pid) baseline fds=${BASE_FD:-?}"

i=1
while [ "$i" -le "$N" ]; do
    echo "== cycle $i/$N"
    "$DOS/bin/desktop-on"  || { echo "FAIL: desktop-on, cycle $i"; exit 1; }
    sleep 5
    "$DOS/bin/desktop-off" || { echo "FAIL: desktop-off, cycle $i"; exit 1; }
    sleep 5
    [ "$(getprop init.svc.surfaceflinger)" = "running" ] || { echo "WEDGE: SF dead after cycle $i"; exit 1; }
    CP=$(composer_pid); FDS=$(ls "/proc/$CP/fd" | wc -l)
    KGSL=$(grep -c . /sys/class/kgsl/kgsl/proc/*/cmdline 2>/dev/null | wc -l)
    echo "cycle $i ok: composer pid=$CP fds=$FDS kgsl-procs=$KGSL"
    i=$((i+1))
done
echo "PASS: $N cycles"
