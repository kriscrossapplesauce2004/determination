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
if ! (LD_LIBRARY_PATH=/usr/local/lib/aarch64-linux-gnu:/usr/local/lib python3 -c "
import gi; gi.require_version('Gm','0'); from gi.repository import Gm
assert Gm.DeviceInfo(compatibles=['qcom,sm8150-mtp']).get_display_panel()" 2>/dev/null); then
    cd /root/build && rm -rf gmobile
    git clone -q --depth 1 -b v0.3.1 https://gitlab.gnome.org/World/Phosh/gmobile.git
    cd gmobile
    for compat in "qcom,sm8150-mtp" "qcom,sm8150"; do
        sed 's/"Oneplus 6T"/"OnePlus 7 (guacamoleb)"/' \
            "data/devices/display-panels/oneplus,fajita.json" \
            > "data/devices/display-panels/${compat}.json"
        grep -q "${compat}.json" data/gmobile.gresources.xml ||
            sed -i "s|\(<file preprocess=\"json-stripblanks\">devices/display-panels/oneplus,fajita.json</file>\)|\1\n    <file preprocess=\"json-stripblanks\">devices/display-panels/${compat}.json</file>|" \
                data/gmobile.gresources.xml
    done
    grep -q sm8150 data/gmobile.gresources.xml || { echo "FATAL: manifest insert failed"; exit 1; }
    meson setup _build --prefix=/usr/local -Dbuildtype=release -Dvapi=false \
        -Dgtk_doc=false -Dexamples=false -Dtests=false -Dman=false >/dev/null
    ninja -C _build >/dev/null && ninja -C _build install >/dev/null
    /usr/sbin/ldconfig
fi
LD_LIBRARY_PATH=/usr/local/lib/aarch64-linux-gnu:/usr/local/lib python3 -c "
import gi; gi.require_version('Gm','0'); from gi.repository import Gm
p = Gm.DeviceInfo(compatibles=['qcom,sm8150-mtp','qcom,sm8150']).get_display_panel()
assert p, 'FATAL: panel not resolved after gmobile build'
print(f'PANEL-OK: {p.get_name()} {p.get_x_res()}x{p.get_y_res()} cutouts={len(p.get_cutouts())}')"

echo "== phosh settings (dconf under /root, persists) =="
# idle-delay 0: phosh's idle blank goes through the same broken
# output-wake path as the power button (KEY_POWER is quirked inert; an
# idle blank would still soft-kill the session). Never blank.
dbus-run-session -- /bin/sh -c '
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
