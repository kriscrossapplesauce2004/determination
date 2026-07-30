#!/bin/bash
# Determination guest polish: mobile apps, notch (gmobile panel JSON), phosh
# settings. Run INSIDE the container as root, in PHONE MODE (guest network
# needs a stable Android framework --- in desktop mode system_server
# crash-loops and takes WiFi down, see AGENTS.md §4 known issues).
# Idempotent.
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp HOME=/root

echo "== apps =="
dpkg --configure -a 2>/dev/null || true
apt-get update -qq
# Core set: kgx (gnome-console, adaptive terminal), calculator, text editor,
# gnome-backgrounds (phosh warns + shows black without any wallpaper),
# python3-gi (gmobile build below + generally useful).
# librsvg2-common --- THE app-icon fix: the GNOME apps ship icons ONLY as
# scalable SVGs (hicolor/scalable/apps/*.svg) and without the GdkPixbuf SVG
# loader this provides, phosh can't rasterize them and every one falls back
# to the generic image placeholder (Foot alone worked --- it ships a PNG).
# Verified 2026-07-08: NO svg loader was in the pixbuf cache.
# feedbackd --- phosh's haptic/LED feedback daemon (org.sigxcpu.Feedback);
# without it phosh/squeekboard spam "Failed to trigger feedback" on every
# button press and there's no key-press haptic. Uses the qti-haptics evdev.
# gnome-control-center --- the Settings app (requested).
apt-get install -y -qq --no-install-recommends \
    gnome-console gnome-calculator gnome-text-editor gnome-backgrounds \
    python3-gi librsvg2-common feedbackd gnome-control-center
# Nice-to-haves that may not exist / may be heavy --- install individually so
# one failure doesn't abort the set. gnome-software = the Software app
# (requested); it wants PackageKit + appstream and may be flaky in-container
# without a full session, but it installs and launches.
for p in gnome-clocks portfolio-filemanager gnome-software; do
    apt-get install -y -qq --no-install-recommends "$p" 2>/dev/null &&
        echo "installed: $p" ||
        echo "skip: $p not installable"
done

echo "== refresh icon + pixbuf caches (SVG loader just landed) =="
# The SVG loader must be registered in the pixbuf loaders cache, and the
# hicolor cache re-indexed so the new app icons are found.
update-gdk-pixbuf-loaders 2>/dev/null ||
    /usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders --update-cache 2>/dev/null || true
for t in hicolor Adwaita; do
    [ -d "/usr/share/icons/$t" ] && gtk-update-icon-cache -f -t "/usr/share/icons/$t" 2>/dev/null || true
done
# Confirm the loader is now present --- fail loud if the icon fix didn't take.
if gdk-pixbuf-query-loaders 2>/dev/null | grep -qi svg; then
    echo "SVG loader OK --- app icons will render"
else
    echo "WARN: SVG loader still absent after librsvg2-common install"
fi

echo "== notch: rebuild libgmobile with an OP7 panel entry =="
# The kernel DT compatible is generic ("qcom,sm8150-mtp qcom,sm8150
# qcom,mtp" --- downstream qcom kernel, no oneplus string), so gmobile's
# embedded panel db never matches --- and gmobile 0.3.1 reads ONLY built-in
# GResources ("currently we only look at the built-in gresources",
# gm-device-info.c), so a filesystem JSON drop-in does nothing. Rebuild
# libgmobile from source with the panel added under our compatibles and
# install to /usr/local (wins via LD_LIBRARY_PATH in desktop-on for BOTH
# phoc and the phosh session --- phosh computes the top-bar margin, so it
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

echo "== favorites: pin whatever actually installed =="
# Build the favorites list from installed .desktop files so a package that
# didn't install (or has a distro-specific desktop id) is skipped rather
# than pinning a dead launcher. Settings ships as org.gnome.Settings on
# modern GNOME; keep gnome-control-center.desktop as a fallback id.
FAVS=""
for id in org.gnome.Settings gnome-control-center org.gnome.Software \
          org.gnome.Console org.gnome.Calculator org.gnome.TextEditor \
          org.gnome.clocks org.gnome.Clocks foot; do
    if [ -f "/usr/share/applications/$id.desktop" ] &&
            ! printf '%s' "$FAVS" | grep -q "$id.desktop"; then
        FAVS="$FAVS\"$id.desktop\", "
    fi
done
FAVS="[${FAVS%, }]"
echo "favorites -> $FAVS"

echo "== phosh settings (dconf under /root, persists) =="
# idle-delay 0: phosh's idle blank goes through the same broken
# output-wake path as the power button (KEY_POWER is quirked inert; an
# idle blank would still soft-kill the session). Never blank.
# color-scheme prefer-dark: big OLED burn-in win (a mostly-black UI draws
# a fraction of the luminance of the light theme over a long static
# session) and the phosh house style anyway.
DARKBG=$(ls /usr/share/backgrounds/gnome/*[Dd]ark*.jpg \
            /usr/share/backgrounds/gnome/*[Nn]ight*.jpg \
            /usr/share/backgrounds/gnome/*-d.jpg 2>/dev/null | head -1)
BG=${DARKBG:-$(ls /usr/share/backgrounds/gnome/*.jpg /usr/share/backgrounds/gnome/*.png 2>/dev/null | head -1)}
export BG FAVS
dbus-run-session -- /bin/sh -c '
    gsettings set org.gnome.desktop.session idle-delay "uint32 0"
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
    gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark" 2>/dev/null || true
    if [ -n "$BG" ]; then
        gsettings set org.gnome.desktop.background picture-uri "file://$BG"
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$BG" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options "zoom"
    fi
    gsettings set sm.puri.phosh favorites "$FAVS" 2>/dev/null ||
        echo "note: sm.puri.phosh favorites key not present in this phosh"
    echo "gsettings done"
'
echo "SETUP-POLISH-OK"
