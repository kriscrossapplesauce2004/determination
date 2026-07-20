#!/bin/sh
# Determination guest SSH server setup. Run INSIDE the container as root.
#
# Usage: setup-ssh.sh /path/to/authorized-key.pub
#
# Idempotent. Password and root SSH logins stay disabled; ordinary password-
# gated sudo inside the guest is unaffected. The host-side `det ssh-setup`
# command supplies the key and installs a direct host route to this private veth.
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export TMPDIR=/tmp HOME=/root

KEY_FILE=${1:-}
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }
[ -n "$KEY_FILE" ] && [ -r "$KEY_FILE" ] || {
    echo "usage: $0 /path/to/authorized-key.pub" >&2
    exit 2
}

# Reject private keys, options-bearing authorized_keys entries, and malformed
# input before touching apt or sshd. Multiple plain public keys are accepted.
# Package hooks may run systemd-tmpfiles and clean the container's /tmp while
# apt is active. Keep the validated key material in root's private directory.
KEYS=$(mktemp /root/determination-ssh-keys.XXXXXX)
trap 'rm -f "$KEYS"' EXIT HUP INT TERM
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    set -- $line
    [ "$#" -ge 2 ] || { echo "FATAL: malformed public key" >&2; exit 2; }
    case "$1" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *) echo "FATAL: unsupported or options-bearing public key: $1" >&2; exit 2 ;;
    esac
    case "$2" in *[!A-Za-z0-9+/=]*) echo "FATAL: malformed public-key data" >&2; exit 2 ;; esac
    printf '%s\n' "$line" >> "$KEYS"
done < "$KEY_FILE"
[ -s "$KEYS" ] || { echo "FATAL: no public keys found" >&2; exit 2; }

echo "== OpenSSH server =="
dpkg --configure -a 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server

getent passwd melissa >/dev/null || { echo "FATAL: guest user melissa is missing" >&2; exit 1; }
home=$(getent passwd melissa | cut -d: -f6)
group=$(id -gn melissa)
install -d -o melissa -g "$group" -m 0700 "$home/.ssh"
touch "$home/.ssh/authorized_keys"
chown melissa:"$group" "$home/.ssh/authorized_keys"
chmod 0600 "$home/.ssh/authorized_keys"

# Match key type + base64 payload, ignoring comments, so reruns do not append
# duplicates merely because a key's comment changed.
while IFS= read -r line; do
    set -- $line
    if ! awk -v type="$1" -v blob="$2" \
        '$1 == type && $2 == blob { found=1 } END { exit !found }' \
        "$home/.ssh/authorized_keys"; then
        printf '%s\n' "$line" >> "$home/.ssh/authorized_keys"
    fi
done < "$KEYS"

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-determination.conf <<'EOF'
# Determination: the guest is administered as melissa with a public key.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers melissa
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
EOF

ssh-keygen -A
sshd -t
systemctl enable ssh >/dev/null
systemctl restart ssh
systemctl --quiet is-active ssh || { echo "FATAL: ssh.service did not start" >&2; exit 1; }

echo "SSH-SETUP-OK — key login for melissa; password/root login disabled"
