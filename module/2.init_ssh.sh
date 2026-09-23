#!/usr/bin/env bash
set -Eeuo pipefail

echo "Starting SSH config..."

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target=/etc/ssh/sshd_config.d/99.custom.conf
backup=$(mktemp)
cloud_backup=""
had_target=0
if [ -f "$target" ]; then
  cp -p "$target" "$backup"
  had_target=1
fi
trap 'rm -f "$backup" "${cloud_backup:-}"' EXIT

install -m 0644 "$SCRIPT_DIR/sshd_config.d/99.custom.conf" "$target"

# Validate before removing provider configuration or restarting SSH.
if ! sshd -t; then
  if [ "$had_target" -eq 1 ]; then cp -p "$backup" "$target"; else rm -f "$target"; fi
  echo "ERROR: SSH config has errors; previous configuration restored." >&2
  exit 1
fi

cloud_config=/etc/ssh/sshd_config.d/50-cloud-init.conf
cloud_backup=$(mktemp)
had_cloud=0
if [ -f "$cloud_config" ]; then
  cp -p "$cloud_config" "$cloud_backup"
  had_cloud=1
  rm -f "$cloud_config"
fi
if ! sshd -t; then
  if [ "$had_cloud" -eq 1 ]; then cp -p "$cloud_backup" "$cloud_config"; fi
  if [ "$had_target" -eq 1 ]; then cp -p "$backup" "$target"; else rm -f "$target"; fi
  rm -f "$cloud_backup"
  echo "ERROR: SSH config became invalid after cloud config removal; previous configuration restored." >&2
  exit 1
fi

sshd_effective=$(sshd -T)
for expected in \
  'port 2001' \
  'passwordauthentication no' \
  'kbdinteractiveauthentication no' \
  'permitrootlogin prohibit-password' \
  'usepam yes'; do
  if ! grep -Fqx "$expected" <<< "$sshd_effective"; then
    if [ "$had_cloud" -eq 1 ]; then cp -p "$cloud_backup" "$cloud_config"; fi
    if [ "$had_target" -eq 1 ]; then cp -p "$backup" "$target"; else rm -f "$target"; fi
    echo "ERROR: effective SSH setting is not '$expected'; previous configuration restored." >&2
    exit 1
  fi
done
if awk '$1 == "pubkeyacceptedalgorithms" { print $2 }' <<< "$sshd_effective" | tr ',' '\n' | grep -Fxq ssh-rsa; then
  if [ "$had_cloud" -eq 1 ]; then cp -p "$cloud_backup" "$cloud_config"; fi
  if [ "$had_target" -eq 1 ]; then cp -p "$backup" "$target"; else rm -f "$target"; fi
  echo "ERROR: insecure ssh-rsa/SHA-1 signatures remain enabled; previous configuration restored." >&2
  exit 1
fi

if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  ssh_service=ssh
else
  ssh_service=sshd
fi
if ! systemctl restart "$ssh_service"; then
  if [ "$had_target" -eq 1 ]; then cp -p "$backup" "$target"; else rm -f "$target"; fi
  if [ "$had_cloud" -eq 1 ]; then cp -p "$cloud_backup" "$cloud_config"; fi
  sshd -t && systemctl restart "$ssh_service" || true
  rm -f "$cloud_backup"
  echo "ERROR: SSH restart failed; previous configuration restored." >&2
  exit 1
fi
rm -f "$cloud_backup"

echo "SSH config completed successfully."
