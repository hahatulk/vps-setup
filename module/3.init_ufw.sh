#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root." >&2
  exit 1
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Script for UFW section
# This sets up UFW firewall

echo "Starting UFW setup..."

apt-get install -y ufw

# Allow ports interactively
read -p "Enter SSH port to allow (default 2001): " ssh_port
ssh_port=${ssh_port:-2001}
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
  echo "Error: invalid SSH port." >&2
  exit 1
fi
ufw allow "${ssh_port}/tcp"
ufw allow https

ufw default deny incoming
ufw default allow outgoing

install -m 0755 "$SCRIPT_DIR/ufw-docker" /usr/local/bin/ufw-docker
# ufw-docker refuses installation while UFW is inactive.
ufw --force enable
ufw-docker install

ufw status verbose

systemctl restart ufw

apt install fail2ban -y

jail_target=/etc/fail2ban/jail.local
jail_backup=$(mktemp)
had_jail=0
if [ -f "$jail_target" ]; then
  cp -p "$jail_target" "$jail_backup"
  had_jail=1
fi
trap 'rm -f "$jail_backup"' EXIT
sed "s/^port[[:space:]]*=.*/port     = $ssh_port/" "$SCRIPT_DIR/fail2ban/jail.local" > "$jail_target"
if ! fail2ban-client -t; then
  if [ "$had_jail" -eq 1 ]; then cp -p "$jail_backup" "$jail_target"; else rm -f "$jail_target"; fi
  echo "Error: fail2ban configuration is invalid; previous file restored." >&2
  exit 1
fi

systemctl enable --now fail2ban
systemctl is-active --quiet fail2ban

echo "UFW setup completed."
echo "To delete a rule: ufw status numbered; ufw delete <number>"
