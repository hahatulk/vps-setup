#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PURGE=0
PURGE_PACKAGES=0
INTERACTIVE_UNINSTALL=0
(($# == 0)) && INTERACTIVE_UNINSTALL=1

usage() {
  cat <<'EOF'
Обычный запуск:
  ./uninstall.sh

Без параметров откроется интерактивное меню удаления.

Для автоматизации доступны [--purge] [--purge-packages].

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

if (( INTERACTIVE_UNINSTALL )); then
  require_interactive_tty
  echo "=== Удаление OpenVPN ==="
  echo
  echo "  1) Удалить сервисы/команды, СОХРАНИТЬ PKI и client profiles"
  echo "  2) Полностью удалить конфигурацию, PKI и client profiles"
  echo "  3) Полностью удалить всё выше + пакеты OpenVPN/Easy-RSA"
  echo "  0) Отмена"
  echo

  while true; do
    IFS= read -r -p "Выбор: " choice || die "Ввод прерван."
    case "$choice" in
      1) break ;;
      2) PURGE=1; break ;;
      3) PURGE=1; PURGE_PACKAGES=1; break ;;
      0) info "Отменено."; exit 0 ;;
      *) warn "Выбери 0, 1, 2 или 3." ;;
    esac
  done

  echo
  if (( PURGE )); then
    warn "Выбран режим с удалением PKI/ключей."
  else
    echo "PKI, CA, server keys и client profiles будут сохранены."
  fi
  prompt_yes_no "Продолжить удаление?" no || {
    info "Отменено."
    exit 0
  }
fi

if (( PURGE )); then
  require_interactive_tty
  echo
  warn "PURGE безвозвратно удалит CA private key, PKI, server keys и client profiles."
  IFS= read -r -p "Для подтверждения введи DELETE: " purge_confirm || die "Ввод прерван."
  [[ "$purge_confirm" == "DELETE" ]] || {
    info "Отменено до изменения системы."
    exit 0
  }
fi

acquire_pki_lock

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
systemctl disable --now "openvpn-server@$SERVER_NAME.service" 2>/dev/null || true

if [[ -x /usr/local/lib/pve-openvpn/pve-openvpn-fw ]]; then
  /usr/local/lib/pve-openvpn/pve-openvpn-fw down || true
fi
systemctl disable --now pve-openvpn-fw.service 2>/dev/null || true

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
  /usr/local/sbin/ovpn \
  /usr/local/sbin/ovpn-add-client \
  /usr/local/sbin/ovpn-revoke-client \
  /usr/local/sbin/ovpn-list-clients \
  /usr/local/sbin/ovpn-status \
  /usr/local/sbin/ovpn-set-mode \
  /usr/local/sbin/ovpn-set-proto \
  /usr/local/sbin/ovpn-upload-nextcloud \
  /usr/local/sbin/ovpn-scrub-client-secret \
  /usr/local/sbin/ovpn-restart \
  /usr/local/sbin/ovpn-routes; do
  if [[ -f "$command_path" && ! -L "$command_path" ]] &&
     grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$command_path"; then
    rm -f -- "$command_path"
  elif [[ -e "$command_path" ]]; then
    warn "Не удаляю изменённую/чужую команду $command_path."
  fi
done

nextcloud_state=/etc/openvpn/pve-nextcloud-upload.conf
if [[ -f "$nextcloud_state" && ! -L "$nextcloud_state" ]] &&
   [[ "$(stat -c '%u:%a' "$nextcloud_state" 2>/dev/null || true)" == "0:600" ]] &&
   grep -Fqx '# Managed by pve-openvpn-kit Nextcloud uploader state v1' "$nextcloud_state"; then
  rm -f -- "$nextcloud_state"
elif [[ -e "$nextcloud_state" || -L "$nextcloud_state" ]]; then
  warn "Не удаляю изменённый/небезопасный $nextcloud_state."
fi

for legacy in /usr/local/sbin/ovpn-fw /usr/local/sbin/ovpn-render-server; do
  if [[ -f "$legacy" && ! -L "$legacy" ]] &&
     grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$legacy"; then
    rm -f -- "$legacy"
  elif [[ -e "$legacy" || -L "$legacy" ]]; then
    warn "Не удаляю изменённый/чужой legacy path $legacy."
  fi
done

lib_dir=/usr/local/lib/pve-openvpn
common_file="$lib_dir/common.sh"
crl_helper="$lib_dir/verify-crl-health"
fw_helper="$lib_dir/pve-openvpn-fw"
render_helper="$lib_dir/pve-openvpn-render-server"
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
for helper in "$fw_helper" "$render_helper"; do
  if [[ -f "$helper" && ! -L "$helper" ]] && grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$helper"; then
    rm -f -- "$helper"
  elif [[ -e "$helper" ]]; then
    warn "Не удаляю изменённый/чужой $helper."
  fi
done
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
  [[ "$EASYRSA_DIR" == "/etc/openvpn/easy-rsa" ]] ||
    die "Отказ от purge: неожиданный EASYRSA_DIR=$EASYRSA_DIR"
  if [[ -e "$EASYRSA_DIR" || -L "$EASYRSA_DIR" ]]; then
    require_secure_root_dir "$EASYRSA_DIR"
    rm -rf --one-file-system -- "$EASYRSA_DIR"
  fi
  rm -f --     "$SERVER_DIR/server.conf"     "$SERVER_DIR/ca.crt"     "$SERVER_DIR/server.crt"     "$SERVER_DIR/server.key"     "$SERVER_DIR/crl.pem"     "$SERVER_DIR/tls-crypt-v2-server.key"     "$SERVER_DIR/tls-crypt.key"
  rm -f -- "$CONFIG_FILE"
  # Никогда не делаем wildcard-delete в произвольном каталоге из вручную
  # изменённого config. Автоматически очищаем profiles только в штатном каталоге.
  if [[ "$CLIENT_DIR" == "$CLIENT_DIR_DEFAULT" ]]; then
    if [[ -d "$CLIENT_DIR" && ! -L "$CLIENT_DIR" ]]; then
      find "$CLIENT_DIR" -maxdepth 1 -type f -name '*.ovpn' -delete
      rmdir -- "$CLIENT_DIR" 2>/dev/null ||
        warn "$CLIENT_DIR не пуст; оставляю чужие файлы и каталог."
    fi
  elif [[ -e "$CLIENT_DIR" ]]; then
    warn "OVPN_CLIENT_DIR изменён на нестандартный путь $CLIENT_DIR; не удаляю из него файлы автоматически."
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
