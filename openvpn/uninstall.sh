#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PURGE=0
PURGE_PACKAGES=0

usage() {
  cat <<'EOF'
Использование:
  ./uninstall.sh [--purge] [--purge-packages]

Без параметров:
  - останавливает OpenVPN;
  - удаляет systemd integration и firewall/NAT chains этого набора;
  - удаляет helper-команды;
  - СОХРАНЯЕТ PKI, CA, server keys и клиентские профили.

--purge:
  дополнительно удаляет PKI/CA, server keys, конфигурацию и клиентские .ovpn.
  Это необратимо и требует ввода DELETE.

--purge-packages:
  также удаляет пакеты openvpn/easy-rsa.
EOF
}

while (($#)); do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --purge-packages) PURGE_PACKAGES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
done

require_root
acquire_pki_lock
acquire_config_lock

SERVER_NAME="$SERVER_NAME_DEFAULT"
CLIENT_DIR="$CLIENT_DIR_DEFAULT"
if [[ -e "$CONFIG_FILE" ]]; then
  config_file_is_secure "$CONFIG_FILE" ||
    die "Отказываюсь source небезопасного $CONFIG_FILE; исправь owner=root и mode=0600."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  SERVER_NAME="${OVPN_SERVER_NAME:-$SERVER_NAME_DEFAULT}"
  CLIENT_DIR="${OVPN_CLIENT_DIR:-$CLIENT_DIR_DEFAULT}"
fi
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] ||
  die "Некорректный OVPN_SERVER_NAME в $CONFIG_FILE."
validate_safe_absolute_dir "$CLIENT_DIR"

info "Останавливаю OpenVPN..."
if systemctl is-active --quiet "openvpn-server@$SERVER_NAME.service"; then
  systemctl stop "openvpn-server@$SERVER_NAME.service" ||
    die "Не удалось остановить OpenVPN; uninstall прерван."
fi
systemctl is-active --quiet "openvpn-server@$SERVER_NAME.service" &&
  die "CRITICAL: OpenVPN всё ещё активен; файлы и firewall не удаляю."
systemctl disable "openvpn-server@$SERVER_NAME.service" 2>/dev/null || true

if [[ -x /usr/local/sbin/ovpn-fw ]]; then
  /usr/local/sbin/ovpn-fw down || die "Не удалось удалить firewall chains; uninstall прерван."
fi
if systemctl is-active --quiet pve-openvpn-fw.service; then
  systemctl stop pve-openvpn-fw.service ||
    die "Не удалось остановить pve-openvpn-fw.service; uninstall прерван."
fi
systemctl is-active --quiet pve-openvpn-fw.service &&
  die "CRITICAL: firewall service всё ещё активен; удаление не продолжаю."
systemctl disable pve-openvpn-fw.service 2>/dev/null || true

unit_file=/etc/systemd/system/pve-openvpn-fw.service
if [[ -f "$unit_file" && ! -L "$unit_file" ]] &&
   grep -Fqx 'Description=PVE OpenVPN forwarding/NAT rules' "$unit_file"; then
  rm -f -- "$unit_file"
elif [[ -e "$unit_file" ]]; then
  warn "Не удаляю изменённый/чужой $unit_file."
fi
# Preserve unrelated administrator drop-ins in the same directory.
dropin_dir="/etc/systemd/system/openvpn-server@$SERVER_NAME.service.d"
dropin_file="$dropin_dir/10-pve-openvpn-security.conf"
if [[ -f "$dropin_file" && ! -L "$dropin_file" ]] &&
   grep -Fqx 'Requires=pve-openvpn-fw.service' "$dropin_file"; then
  rm -f -- "$dropin_file"
elif [[ -e "$dropin_file" ]]; then
  warn "Не удаляю изменённый/чужой $dropin_file."
fi
rmdir -- "$dropin_dir" 2>/dev/null || true
systemctl daemon-reload

for command_path in \
  /usr/local/sbin/ovpn-add-client \
  /usr/local/sbin/ovpn-revoke-client \
  /usr/local/sbin/ovpn-list-clients \
  /usr/local/sbin/ovpn-status \
  /usr/local/sbin/ovpn-set-mode \
  /usr/local/sbin/ovpn-scrub-client-secret \
  /usr/local/sbin/ovpn-render-server \
  /usr/local/sbin/ovpn-fw; do
  if [[ -f "$command_path" && ! -L "$command_path" ]] &&
     grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$command_path"; then
    rm -f -- "$command_path"
  elif [[ -e "$command_path" ]]; then
    warn "Не удаляю изменённую/чужую команду $command_path."
  fi
done
lib_dir=/usr/local/lib/pve-openvpn
common_file="$lib_dir/common.sh"
crl_helper="$lib_dir/verify-crl-health"
if [[ -f "$common_file" && ! -L "$common_file" ]] && grep -Fq 'CONFIG_FILE="/etc/openvpn/pve-openvpn.conf"' "$common_file"; then
  rm -f -- "$common_file"
elif [[ -e "$common_file" ]]; then
  warn "Не удаляю изменённый/чужой $common_file."
fi
if [[ -f "$crl_helper" && ! -L "$crl_helper" ]] && grep -Fq 'CRL="/etc/openvpn/server/crl.pem"' "$crl_helper"; then
  rm -f -- "$crl_helper"
elif [[ -e "$crl_helper" ]]; then
  warn "Не удаляю изменённый/чужой $crl_helper."
fi
rmdir -- "$lib_dir" 2>/dev/null || true

sysctl_file=/etc/sysctl.d/99-pve-openvpn.conf
if [[ -f "$sysctl_file" && ! -L "$sysctl_file" ]] &&
   grep -Fqx '# Managed by pve-openvpn-kit' "$sysctl_file"; then
  rm -f -- "$sysctl_file"
elif [[ -e "$sysctl_file" ]]; then
  warn "Не удаляю изменённый/чужой $sysctl_file."
fi
warn "net.ipv4.ip_forward не выключаю автоматически: forwarding может использоваться VM/LXC/NAT."

if (( PURGE )); then
  echo
  warn "Будут удалены CA private key, PKI, server keys и клиентские профили."
  read -r -p "Для подтверждения введи DELETE: " confirm
  [[ "$confirm" == "DELETE" ]] || die "Отменено."

  rm -rf -- "$EASYRSA_DIR"
  rm -f --     "$SERVER_DIR/server.conf"     "$SERVER_DIR/ca.crt"     "$SERVER_DIR/server.crt"     "$SERVER_DIR/server.key"     "$SERVER_DIR/crl.pem"     "$SERVER_DIR/tls-crypt-v2-server.key"     "$SERVER_DIR/tls-crypt.key"
  rm -f -- "$CONFIG_FILE"
  # Delete only generated profiles; preserve unrelated files if an administrator
  # pointed OVPN_CLIENT_DIR at a shared directory.
  if [[ -d "$CLIENT_DIR" && ! -L "$CLIENT_DIR" ]]; then
    find "$CLIENT_DIR" -maxdepth 1 -type f -name '*.ovpn' -delete
    rmdir -- "$CLIENT_DIR" 2>/dev/null ||
      warn "$CLIENT_DIR не пуст; оставляю чужие файлы и каталог."
  fi
  info "PKI и секреты этого набора удалены."
else
  info "PKI и клиентские профили сохранены."
fi

if (( PURGE_PACKAGES )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove --purge -y openvpn easy-rsa
  apt-get autoremove -y
fi

info "Готово."
