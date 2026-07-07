#!/bin/bash
# DecemberOS guest polish: mobile apps, notch (gmobile panel JSON), phosh
# settings. Run INSIDE the container as root, in PHONE MODE (guest network
# needs a stable Android framework — in desktop mode system_server
# crash-loops and takes WiFi down, see CLAUDE.md §4 known issues).
# Idempotent.
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp HOME=/root

echo "== apps =="
dpkg --configure -a 2>/dev/null || true
apt-get update -qq
# Core set: kgx (gnome-console, adaptive terminal), calculator, text editor,
# gnome-backgrounds (phosh warns + shows black without any wallpaper),
# python3-gi (gmobile extraction below + generally useful).
apt-get install -y -qq --no-install-recommends \
    gnome-console gnome-calculator gnome-text-editor gnome-backgrounds \
    python3-gi
# Nice-to-haves that may not exist in trixie — install individually.
for p in portfolio-filemanager gnome-clocks; do
    apt-get install -y -qq --no-install-recommends "$p" 2>/dev/null ||
        echo "skip: $p not installable"
done

echo "== notch: rebuild libgmobile with an OP7 panel entry =="
# The kernel DT compatible is generic ("qcom,sm8150-mtp qcom,sm8150
# qcom,mtp" — downstream qcom kernel, no oneplus string), so gmobile's
# embedded panel db never matches — and gmobile 0.3.1 reads ONLY built-in
# GResources ("currently we only look at the built-in gresources",
# gm-device-info.c), so a filesystem JSON drop-in does nothing. Rebuild
# libgmobile from source with the panel added under our compatibles and
# install to /usr/local (wins via LD_LIBRARY_PATH in desktop-on for BOTH
# phoc and the phosh session — phosh computes the top-bar margin, so it
# needs our lib too). The OnePlus 6T (fajita) JSON is the same 1080x2340
# waterdrop glass; reuse its cutout path.
# Idempotency: rebuild unless the RIGHT panel is installed (a 170px-wide
# cutout — the first attempt copied fajita's 368px-wide path and phosh's
# clock-shift algorithm can't clear that, g_warning "No clock placement
# found to fully avoid notch").
if ! (LD_LIBRARY_PATH=/usr/local/lib/aarch64-linux-gnu:/usr/local/lib python3 -c "
import gi; gi.require_version('Gm','0'); from gi.repository import Gm
p = Gm.DeviceInfo(compatibles=['qcom,sm8150-mtp']).get_display_panel()
assert p and p.get_cutouts()[0].get_bounds().width == 170" 2>/dev/null); then
    cd /root/build
    [ -d gmobile ] || git clone -q --depth 1 -b v0.3.1 https://gitlab.gnome.org/World/Phosh/gmobile.git
    cd gmobile
    for compat in "qcom,sm8150-mtp" "qcom,sm8150"; do
        # NOTE the uppercase Z: gmobile's SVG path parser silently fails
        # on lowercase 'z' and the cutout bounds come back 0x0.
        cat > "data/devices/display-panels/${compat}.json" <<'JSONEOF'
{
  "name": "OnePlus 7 (guacamoleb)",
  "x-res": 1080,
  "y-res": 2340,
  "border-radius": 120,
  "width": 68,
  "height": 149,
  "cutouts" : [
    {
      "name": "notch",
      "path": "M 455,0 h 170 c -4,44 -36,82 -85,82 c -49,0 -81,-38 -85,-82 Z"
    }
  ]
}
JSONEOF
        grep -q "${compat}.json" data/gmobile.gresources.xml ||
            sed -i "s|\(<file preprocess=\"json-stripblanks\">devices/display-panels/oneplus,fajita.json</file>\)|\1\n    <file preprocess=\"json-stripblanks\">devices/display-panels/${compat}.json</file>|" \
                data/gmobile.gresources.xml
    done
    grep -q sm8150 data/gmobile.gresources.xml || { echo "FATAL: manifest insert failed"; exit 1; }
    # Clean build dir every time: meson does NOT retrack edited gresource
    # inputs reliably (stale panel shipped once, 2026-07-07).
    rm -rf _build
    meson setup _build --prefix=/usr/local -Dbuildtype=release -Dvapi=false \
        -Dgtk_doc=false -Dexamples=false -Dtests=false -Dman=false >/dev/null
    ninja -C _build >/dev/null && ninja -C _build install >/dev/null
    /usr/sbin/ldconfig
fi
LD_LIBRARY_PATH=/usr/local/lib/aarch64-linux-gnu:/usr/local/lib python3 -c "
import gi; gi.require_version('Gm','0'); from gi.repository import Gm
p = Gm.DeviceInfo(compatibles=['qcom,sm8150-mtp','qcom,sm8150']).get_display_panel()
b = p.get_cutouts()[0].get_bounds()
assert b.width == 170, f'FATAL: wrong cutout installed (w={b.width})'
print(f'PANEL-OK: {p.get_name()} cutout x={b.x} w={b.width} h={b.height}')"

echo "== squeekboard key icons (Debian ships none: key-shift/key-enter/"
echo "   keyboard-mode render as literal icon placeholders) =="
if [ ! -f /usr/share/icons/hicolor/scalable/actions/key-shift.svg ]; then
    cd /tmp
    curl -sfLO "https://deb.debian.org/debian/pool/main/s/squeekboard/squeekboard_1.43.1.orig.tar.bz2"
    tar xf squeekboard_1.43.1.orig.tar.bz2 --wildcards "*/data/icons/*.svg"
    mkdir -p /usr/share/icons/hicolor/scalable/actions
    cp squeekboard-v1.43.1/data/icons/*.svg /usr/share/icons/hicolor/scalable/actions/
    gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
fi
echo "key icons: $(ls /usr/share/icons/hicolor/scalable/actions/ | grep -c '^key')"

echo "== timezone (guest clock showed UTC in the top bar) =="
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
echo Europe/London > /etc/timezone

echo "== apt: force IPv4 (AAAA resolves but v6 has no route out through the"
echo "   NAT -> every apt connect burns a timeout before falling back) =="
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

echo "== phosh settings (dconf under /root, persists) =="
# idle-delay 0: phosh's idle blank goes through the same broken
# output-wake path as the power button (KEY_POWER is quirked inert; an
# idle blank would still soft-kill the session). Never blank.
dbus-run-session -- /bin/sh -c '
    # shell-layout=device is the master switch for notch handling: phosh
    # get_clock_pos() returns CENTER unconditionally unless it is set
    # (found reading phosh 0.46 src/layout-manager.c — nothing else,
    # including a perfect gmobile panel, has any effect without it).
    gsettings set sm.puri.phosh shell-layout device
    gsettings set org.gnome.desktop.session idle-delay "uint32 0"
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    BG=$(ls /usr/share/backgrounds/gnome/*.jpg /usr/share/backgrounds/gnome/*.png 2>/dev/null | head -1)
    [ -n "$BG" ] && gsettings set org.gnome.desktop.background picture-uri "file://$BG" &&
        gsettings set org.gnome.desktop.background picture-options "zoom"
    gsettings set sm.puri.phosh favorites "[\"org.gnome.Console.desktop\",\"org.gnome.Calculator.desktop\",\"org.gnome.TextEditor.desktop\",\"foot.desktop\"]" 2>/dev/null ||
        echo "note: sm.puri.phosh favorites key not present in this phosh"
    echo "gsettings done"
'
echo "SETUP-POLISH-OK"
