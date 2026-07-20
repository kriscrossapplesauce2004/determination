#!/bin/sh
# Determination guest MOTD. Run inside the container as root.
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp HOME=/root

VERSION=${1:-unknown}
CODENAME=${2:-}

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }

# SSH inherits the local terminal's TERM. Terra uses Kitty, and without its
# terminfo entry even basic commands such as clear fail with "unknown terminal
# type". Install the tiny definition package once; subsequent runs are no-ops.
if ! infocmp xterm-kitty >/dev/null 2>&1; then
    apt-get install -y -qq --no-install-recommends kitty-terminfo
fi

# The MOTD is the welcome. Do not staple Fish's tutorial greeting beneath it.
install -d -m 0755 /etc/fish/conf.d
cat > /etc/fish/conf.d/00-determination.fish <<'EOF'
set -g fish_greeting
EOF
chmod 0644 /etc/fish/conf.d/00-determination.fish

# Keep the login visually MOTD -> prompt. Host-key and authentication policy
# remain in the separate SSH setup drop-in.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/55-determination-motd.conf <<'EOF'
PrintLastLog no
EOF
/usr/sbin/sshd -t
systemctl reload ssh 2>/dev/null || true

# This is the canonical project hostname; older live rootfs images still carry
# the pre-rename "decemberos" value.
printf 'determination\n' > /etc/hostname
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tdetermination/' /etc/hosts
else
    printf '127.0.1.1\tdetermination\n' >> /etc/hosts
fi
hostname determination

cat > /etc/determination-release <<EOF
DET_VERSION='$VERSION'
DET_CODENAME='$CODENAME'
EOF
chmod 0644 /etc/determination-release

cat > /etc/update-motd.d/00-determination <<'EOF'
#!/bin/sh
# Fastfetch-style MOTD without fastfetch: that binary currently prints its
# report and then SIGSEGVs on the downstream 4.14 kernel.

pink=$(printf '\033[38;5;204m')
gold=$(printf '\033[38;5;221m')
text=$(printf '\033[38;5;252m')
reset=$(printf '\033[0m')

. /etc/os-release
[ ! -r /etc/determination-release ] || . /etc/determination-release
[ ! -r /etc/determination-device.conf ] || . /etc/determination-device.conf

arch=$(uname -m)
kernel=$(uname -r)
host=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || printf 'Android device')
address=$(ip -4 -o address show dev eth0 2>/dev/null |
    awk 'NR == 1 { split($4, a, "/"); print a[1] }')
[ -n "$address" ] || address='offline'

uptime=$(awk '{
    s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60)
    if (d) printf "%dd %dh", d, h
    else if (h) printf "%dh %dm", h, m
    else printf "%dm", m
}' /proc/uptime)

memory=$(awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { avail=$2 }
    END { printf "%.1f / %.1f GiB", (total-avail)/1048576, total/1048576 }
' /proc/meminfo)

session='headless'
pgrep -x phoc >/dev/null 2>&1 && session='desktop'

battery='unavailable'
gauge=${DET_BATTERY_GAUGE:-bms}
if [ -r "/sys/class/power_supply/$gauge/capacity" ]; then
    battery="$(cat "/sys/class/power_supply/$gauge/capacity")%"
fi

release=${DET_CODENAME:-Determination}
[ "${DET_VERSION:-unknown}" = unknown ] || release="$release ${DET_VERSION}"

row() {
    printf '%b%-31b%b%-9s%b%s%b\n' "$pink" "$1" "$pink" "$2" "$text" "$3" "$reset"
}

row '       _,met$$$$$gg.' 'melissa' '@determination'
row '    ,g$$$$$$$$$$$$$$$P.' '---------' '--------------'
row '  ,g$$P"     """Y$$.".' 'OS:' "$PRETTY_NAME $arch"
row ' ,$$P\047              `$$$.' 'Host:' "$host"
row '\047,$$P       ,ggs.     `$$b:' 'Kernel:' "$kernel"
row '`d$$\047     ,$P"\047   .    $$$' 'Uptime:' "$uptime"
row ' $$P      d$\047     ,    $$P' 'Session:' "$session"
row ' $$:      $$.   -    ,d$$\047' 'Memory:' "$memory"
row ' $$;      Y$b._   _,d$P\047' 'Battery:' "$battery"
row ' Y$$.    `.`"Y$$$$P"\047' 'Address:' "$address"
row ' `$$b      "-.__' 'Release:' "$release"
row '  `Y$$' '' ''
row '   `Y$$.' '' ''
row '     `$$b.' '' ''
printf '%b\n' "$reset"
EOF
chmod 0755 /etc/update-motd.d/00-determination

# Debian's stock entries duplicate fields above; /etc/motd contains the generic
# warranty paragraph. Leave neither stapled below the custom output.
for entry in /etc/update-motd.d/*; do
    [ "$entry" = /etc/update-motd.d/00-determination ] || chmod -x "$entry"
done
: > /etc/motd

run-parts /etc/update-motd.d > /run/motd.dynamic
chmod 0644 /run/motd.dynamic

echo "MOTD-SETUP-OK"
cat /run/motd.dynamic
