#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ENDPOINT=""
PORT="1194"
PROTO="udp"
VPN_CIDR="10.8.0.0/24"
WAN_IF=""
MODE="split"
LANS=()
DNS_SERVERS=("1.1.1.1" "9.9.9.9")
TUN_IF="tun0"
SERVER_NAME="server"
CLIENT_DIR="/root/openvpn-clients"
MAX_CLIENTS="64"
CA_NOPASS=0
TLS_COOKIE="force-cookie"
CRL_DAYS="3650"
INTERACTIVE_INSTALL=0
(($# == 0)) && INTERACTIVE_INSTALL=1

assert_managed_file_or_absent() {
  local file="$1" marker="$2"
  [[ -e "$file" || -L "$file" ]] || return 0
  secure_root_file "$file" ||
    die "Не перезаписываю небезопасный $file: нужен regular root-owned file без group/other write."
  grep -Fq "$marker" "$file" || die "Не перезаписываю чужой $file."
}

atomic_install_file() {
  local src="$1" dst="$2" mode="$3" dir base tmp

  [[ -f "$src" && ! -L "$src" ]] || die "Источник для установки должен быть regular file, не symlink: $src"
  dir="$(dirname -- "$dst")"
  base="$(basename -- "$dst")"
  require_secure_root_dir "$dir"

  tmp="$(mktemp "$dir/.${base}.new.XXXXXX")"
  if ! install -o root -g root -m "$mode" "$src" "$tmp"; then
    rm -f -- "$tmp"
    die "Не удалось подготовить обновление $dst."
  fi
  if ! mv -fT -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    die "Не удалось атомарно заменить $dst."
  fi
}

managed_install_present() {
  # Этот marker создаётся только нашим installer-ом. Для update-only достаточно
  # защищённого root-owned config: даже если server.conf временно сломан/удалён,
  # повторный install.sh не должен внезапно запускать первичный мастер.
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || return 1
  secure_root_file "$CONFIG_FILE" || return 1
  grep -Fqx '# Managed by pve-openvpn-kit; shell assignments, mode 0600.' "$CONFIG_FILE"
}

update_tooling_only() {
  local mode="${1:-update}" target f legacy

  if [[ "$mode" == "update" ]]; then
    info "Обнаружена существующая установка pve-openvpn-kit."
    info "Обновляю только управляющие скрипты и внутренние helpers."
    echo "  OpenVPN packages:  не трогаю"
    echo "  PKI/CA:            не трогаю"
    echo "  server.conf:       не трогаю"
    echo "  firewall/systemd:  не перезапускаю"
    echo
  else
    info "Устанавливаю управляющие скрипты и внутренние helpers..."
  fi

  if [[ -e /usr/local/lib/pve-openvpn || -L /usr/local/lib/pve-openvpn ]]; then
    require_secure_root_dir /usr/local/lib/pve-openvpn
  fi
  require_secure_root_dir /usr/local/sbin

  for target in \
    /usr/local/lib/pve-openvpn/common.sh \
    /usr/local/lib/pve-openvpn/verify-crl-health \
    /usr/local/lib/pve-openvpn/pve-openvpn-fw \
    /usr/local/lib/pve-openvpn/pve-openvpn-render-server; do
    if [[ -e "$target" || -L "$target" ]]; then
      secure_root_file "$target" ||
        die "Не перезаписываю небезопасный/не-root-owned $target."
      case "$target" in
        */common.sh)
          grep -Fq 'CONFIG_FILE="/etc/openvpn/pve-openvpn.conf"' "$target" ||
            die "Не перезаписываю чужой $target."
          ;;
        */verify-crl-health)
          grep -Fq 'CRL="/etc/openvpn/server/crl.pem"' "$target" ||
            die "Не перезаписываю чужой $target."
          ;;
        *)
          grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$target" ||
            die "Не перезаписываю чужой внутренний helper $target."
          ;;
      esac
    fi
  done

  for f in "$SCRIPT_DIR"/bin/ovpn*; do
    target="/usr/local/sbin/$(basename "$f")"
    if [[ -e "$target" || -L "$target" ]]; then
      secure_root_file "$target" ||
        die "Не перезаписываю небезопасную/не-root-owned команду $target."
      grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$target" ||
        die "Не перезаписываю чужую команду $target. Удали/переименуй её вручную."
    fi
  done

  install -d -o root -g root -m 0755 /usr/local/lib/pve-openvpn /usr/local/sbin
  atomic_install_file "$SCRIPT_DIR/lib/common.sh" /usr/local/lib/pve-openvpn/common.sh 0644
  atomic_install_file "$SCRIPT_DIR/lib/verify-crl-health" /usr/local/lib/pve-openvpn/verify-crl-health 0755
  atomic_install_file "$SCRIPT_DIR/lib/pve-openvpn-fw" /usr/local/lib/pve-openvpn/pve-openvpn-fw 0755
  atomic_install_file "$SCRIPT_DIR/lib/pve-openvpn-render-server" /usr/local/lib/pve-openvpn/pve-openvpn-render-server 0755

  for f in "$SCRIPT_DIR"/bin/ovpn*; do
    atomic_install_file "$f" "/usr/local/sbin/$(basename "$f")" 0755
  done

  for legacy in /usr/local/sbin/ovpn-fw /usr/local/sbin/ovpn-render-server; do
    if [[ -f "$legacy" && ! -L "$legacy" ]] &&
       grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$legacy"; then
      rm -f -- "$legacy"
    elif [[ -e "$legacy" || -L "$legacy" ]]; then
      warn "Найден чужой/изменённый legacy path $legacy; не удаляю его автоматически."
    fi
  done

  if [[ "$mode" == "update" ]]; then
    info "Скрипты обновлены. Работающий OpenVPN не изменялся и не перезапускался."
  else
    info "Управляющие скрипты установлены."
  fi
}

usage() {
  cat <<'EOF'
Установка OpenVPN для Proxmox VE 9 / Debian 13.

Обычная интерактивная установка:
  ./install.sh

Скрипт сам спросит endpoint, транспорт UDP/TCP, порт, WAN, VPN subnet, LAN-сети,
split/full режим, DNS, совместимость tls-crypt-v2 и защиту CA.

Опции ниже сохранены только для осознанной автоматизации/CI:
  --endpoint HOST_OR_IP     Публичный IPv4 или DNS-имя VPN-сервера.
  --proto udp|tcp           Транспорт OpenVPN (по умолчанию udp).
  --port PORT               TCP/UDP-порт (по умолчанию 1194).
  --wan IFACE               WAN/bridge, например vmbr0. Иначе определяется по default route.
  --vpn-cidr CIDR           VPN IPv4 subnet (по умолчанию 10.8.0.0/24).
  --lan CIDR                Разрешённая через VPN LAN/VM сеть. Можно повторять.
  --mode split|full         split по умолчанию; full отправляет весь IPv4 клиента через VPN.
  --dns IPv4                DNS для full-tunnel. Первый --dns заменяет defaults.
  --max-clients N           Лимит одновременных клиентов (по умолчанию 64).
  --allow-noncookie         Совместимость со старыми tls-crypt-v2 клиентами.
                            По умолчанию используется более строгий force-cookie.
  --ca-nopass               НЕ РЕКОМЕНДУЕТСЯ: CA key без пароля для unattended PKI.
  -h, --help                Помощь.

Примеры:
  ./install.sh --endpoint vpn.example.com --lan 192.168.1.0/24

  ./install.sh --endpoint 203.0.113.10 --wan vmbr0 \
    --lan 192.168.1.0/24 --lan 10.20.0.0/24

  ./install.sh --endpoint vpn.example.com --mode full --dns 1.1.1.1

Без --ca-nopass Easy-RSA попросит пароль CA при первом создании PKI,
а затем при выпуске/отзыве сертификатов. Это рекомендуемый режим.
EOF
}

dns_overridden=0
while (($#)); do
  case "$1" in
    --endpoint)
      [[ $# -ge 2 ]] || die "Для --endpoint нужно значение."
      ENDPOINT="$2"; shift 2
      ;;
    --proto)
      [[ $# -ge 2 ]] || die "Для --proto нужно значение."
      PROTO="${2,,}"; shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "Для --port нужно значение."
      PORT="$2"; shift 2
      ;;
    --wan)
      [[ $# -ge 2 ]] || die "Для --wan нужно значение."
      WAN_IF="$2"; shift 2
      ;;
    --vpn-cidr)
      [[ $# -ge 2 ]] || die "Для --vpn-cidr нужно значение."
      VPN_CIDR="$2"; shift 2
      ;;
    --lan)
      [[ $# -ge 2 ]] || die "Для --lan нужно значение."
      LANS+=("$2"); shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "Для --mode нужно значение."
      MODE="$2"; shift 2
      ;;
    --dns)
      [[ $# -ge 2 ]] || die "Для --dns нужно значение."
      if (( ! dns_overridden )); then
        DNS_SERVERS=()
        dns_overridden=1
      fi
      DNS_SERVERS+=("$2"); shift 2
      ;;
    --max-clients)
      [[ $# -ge 2 ]] || die "Для --max-clients нужно значение."
      MAX_CLIENTS="$2"; shift 2
      ;;
    --allow-noncookie)
      TLS_COOKIE="allow-noncookie"; shift
      ;;
    --ca-nopass)
      CA_NOPASS=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "Неизвестный параметр: $1. Используй --help."
      ;;
  esac
done

require_root

# Повторный запуск на существующей установке этого набора — это updater.
# Никаких prompt-ов, apt, PKI, firewall/systemd изменений или restart.
if managed_install_present; then
  require_cmd flock
  if [[ -e /run/pve-openvpn || -L /run/pve-openvpn ]]; then
    [[ -d /run/pve-openvpn && ! -L /run/pve-openvpn ]] ||
      die "Небезопасный runtime directory: /run/pve-openvpn"
  fi
  install -d -o root -g root -m 0700 /run/pve-openvpn
  exec 7>/run/pve-openvpn/config.lock
  flock -x -w 30 7 || die "Конфигурация занята другой операцией. Повтори позже."
  acquire_pki_lock

  update_tooling_only update
  exit 0
fi

if (( INTERACTIVE_INSTALL )); then
  require_interactive_tty
  echo "=== Установка OpenVPN для Proxmox VE 9 / Debian 13 ==="
  echo

  ENDPOINT="$(prompt_nonempty "Публичный IPv4 или DNS-имя VPN (например vpn.example.com): ")"

  echo
  echo "Транспорт OpenVPN:"
  echo "  1) UDP — рекомендуется: быстрее и без TCP-over-TCP проблем"
  echo "  2) TCP — используй, если UDP блокируется сетью/провайдером"
  while true; do
    IFS= read -r -p "Выбор [1]: " proto_choice || die "Ввод прерван."
    proto_choice="${proto_choice:-1}"
    case "$proto_choice" in
      1) PROTO="udp"; break ;;
      2) PROTO="tcp"; break ;;
      *) warn "Выбери 1 или 2." ;;
    esac
  done

  PORT="$(prompt_with_default "${PROTO^^}-порт OpenVPN" "$PORT")"

  detected_wan="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  if [[ -n "$detected_wan" ]]; then
    WAN_IF="$(prompt_with_default "WAN/bridge интерфейс" "$detected_wan")"
  else
    WAN_IF="$(prompt_nonempty "WAN/bridge интерфейс (например vmbr0): ")"
  fi

  VPN_CIDR="$(prompt_with_default "VPN IPv4 subnet" "$VPN_CIDR")"
  MAX_CLIENTS="$(prompt_with_default "Максимум одновременных клиентов" "$MAX_CLIENTS")"

  echo
  echo "Режим:"
  echo "  1) split — через VPN только выбранные LAN/VM сети (рекомендуется)"
  echo "  2) full  — весь IPv4 клиента через VPN"
  while true; do
    IFS= read -r -p "Выбор [1]: " mode_choice || die "Ввод прерван."
    mode_choice="${mode_choice:-1}"
    case "$mode_choice" in
      1) MODE="split"; break ;;
      2) MODE="full"; break ;;
      *) warn "Выбери 1 или 2." ;;
    esac
  done

  echo
  echo "Добавь LAN/VM сети, доступные VPN-клиентам."
  echo "Пример: 192.168.1.0/24 или 10.20.0.0/24."
  echo "Пустой ввод завершает список."
  while true; do
    IFS= read -r -p "LAN CIDR (Enter = закончить): " lan || die "Ввод прерван."
    [[ -n "$lan" ]] || break
    LANS+=("$lan")
  done

  if [[ "$MODE" == "full" ]]; then
    echo
    echo "DNS для full-tunnel. По умолчанию: ${DNS_SERVERS[*]}"
    if prompt_yes_no "Изменить DNS?" no; then
      DNS_SERVERS=()
      while true; do
        IFS= read -r -p "DNS IPv4 (Enter = закончить): " dns || die "Ввод прерван."
        [[ -n "$dns" ]] || break
        DNS_SERVERS+=("$dns")
      done
      ((${#DNS_SERVERS[@]} > 0)) || die "Для full-tunnel после выбора изменения DNS нужен хотя бы один DNS."
    fi
  fi

  echo
  if [[ "$PROTO" == "udp" ]]; then
    if prompt_yes_no "Нужна совместимость со старыми tls-crypt-v2 клиентами (allow-noncookie)?" no; then
      TLS_COOKIE="allow-noncookie"
    fi
  else
    echo "TCP выбран: UDP cookie-handshake force-cookie не применяется; tls-crypt-v2 остаётся включённым."
  fi

  echo
  echo "CA private key по умолчанию защищается passphrase — это безопаснее."
  if ! prompt_yes_no "Защитить CA passphrase?" yes; then
    warn "Выбран CA без passphrase. Это снижает защиту при краже файлов PKI."
    IFS= read -r -p "Для подтверждения небезопасного режима введи NOPASS: " ca_confirm || die "Ввод прерван."
    [[ "$ca_confirm" == "NOPASS" ]] || die "Отменено."
    CA_NOPASS=1
  fi
fi

[[ -n "$ENDPOINT" ]] || die "Не задан endpoint."
validate_endpoint "$ENDPOINT"

[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "Некорректный порт: $PORT"
PORT=$((10#$PORT))
(( PORT >= 1 && PORT <= 65535 )) || die "Некорректный порт: $PORT"
[[ "$PROTO" == "udp" || "$PROTO" == "tcp" ]] ||
  die "--proto должен быть udp или tcp."
[[ "$MODE" == "split" || "$MODE" == "full" ]] ||
  die "--mode должен быть split или full."
[[ "$MAX_CLIENTS" =~ ^[0-9]{1,4}$ ]] || die "--max-clients должен быть числом."
MAX_CLIENTS=$((10#$MAX_CLIENTS))
(( MAX_CLIENTS >= 1 && MAX_CLIENTS <= 4096 )) ||
  die "--max-clients должен быть 1..4096."

VPN_CIDR="$(normalize_cidr "$VPN_CIDR")"
vpn_prefix="$(cidr_prefix "$VPN_CIDR")"
(( vpn_prefix >= 8 && vpn_prefix <= 30 )) ||
  die "VPN subnet должен иметь разумный IPv4 prefix /8..../30."

for dns in "${DNS_SERVERS[@]}"; do
  validate_ipv4 "$dns"
done

# Нормализуем LAN CIDR, убираем точные дубликаты и запрещаем overlap с VPN pool.
declare -A seen_lans=()
normalized_lans=()
for lan in "${LANS[@]}"; do
  lan="$(normalize_cidr "$lan")"
  [[ "$(cidr_prefix "$lan")" != "0" ]] ||
    die "--lan 0.0.0.0/0 запрещён; для full-tunnel используй --mode full."
  if cidr_overlap "$VPN_CIDR" "$lan"; then
    die "VPN subnet $VPN_CIDR пересекается с разрешённой LAN $lan."
  fi
  if [[ -z "${seen_lans[$lan]:-}" ]]; then
    normalized_lans+=("$lan")
    seen_lans["$lan"]=1
  fi
done
LANS=("${normalized_lans[@]}")

if [[ -z "$WAN_IF" ]]; then
  WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
fi
[[ -n "$WAN_IF" ]] ||
  die "Не удалось определить WAN-интерфейс. Укажи --wan, например --wan vmbr0."
[[ "$WAN_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "Некорректное имя WAN-интерфейса: $WAN_IF"
ip link show "$WAN_IF" >/dev/null 2>&1 ||
  die "Интерфейс '$WAN_IF' не существует."

# Не позволяем молча поднять VPN subnet поверх уже существующей IPv4 сети.
while read -r dest rest; do
  [[ -n "$dest" && "$dest" != "default" ]] || continue
  [[ "$rest" == *" dev $TUN_IF"* ]] && continue

  route_cidr=""
  if [[ "$dest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    route_cidr="$dest"
  elif [[ "$dest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    route_cidr="$dest/32"
  fi

  [[ -n "$route_cidr" ]] || continue
  if cidr_overlap "$VPN_CIDR" "$route_cidr"; then
    die "VPN subnet $VPN_CIDR пересекается с существующим маршрутом: $dest $rest"
  fi
done < <(ip -4 route show)

info "Конфигурация:"
echo "  Endpoint:       $ENDPOINT:$PORT/$PROTO"
echo "  WAN:            $WAN_IF"
echo "  VPN subnet:     $VPN_CIDR"
echo "  Mode:           $MODE"
echo "  Max clients:    $MAX_CLIENTS"
echo "  LAN routes:     ${LANS[*]:-(нет)}"
echo "  DNS(full):      ${DNS_SERVERS[*]:-(нет)}"
if [[ "$PROTO" == "udp" ]]; then
  echo "  tls-crypt-v2:   $TLS_COOKIE"
else
  echo "  tls-crypt-v2:   enabled (cookie mode: n/a for TCP)"
fi
if (( CA_NOPASS )); then
  warn "CA private key будет БЕЗ пароля (--ca-nopass)."
else
  echo "  CA key:         password protected"
fi
echo

if (( INTERACTIVE_INSTALL )); then
  prompt_yes_no "Начать установку с указанными настройками?" no || {
    info "Установка отменена до изменения системы."
    exit 0
  }
  echo
fi

if [[ "$MODE" == "full" ]]; then
  warn "Full-tunnel в этом наборе — IPv4. IPv6 клиента не туннелируется; см. SECURITY.md."
fi

# Fail before package/PKI changes rather than overwrite files owned by another setup.
assert_managed_file_or_absent "$CONFIG_FILE" '# Managed by pve-openvpn-kit; shell assignments, mode 0600.'
assert_managed_file_or_absent "$SERVER_DIR/$SERVER_NAME.conf" '# Generated by pve-openvpn-kit.'
assert_managed_file_or_absent /etc/sysctl.d/99-pve-openvpn.conf '# Managed by pve-openvpn-kit'
assert_managed_file_or_absent /etc/systemd/system/pve-openvpn-fw.service 'Description=PVE OpenVPN forwarding/NAT rules'
assert_managed_file_or_absent "/etc/systemd/system/openvpn-server@$SERVER_NAME.service.d/10-pve-openvpn-security.conf" 'Requires=pve-openvpn-fw.service'

export DEBIAN_FRONTEND=noninteractive
require_cmd dpkg-query
packages=(openvpn easy-rsa iptables ca-certificates openssl util-linux iproute2 kmod)
missing_packages=()
for pkg in "${packages[@]}"; do
  if ! dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -Fqx 'install ok installed'; then
    missing_packages+=("$pkg")
  fi
done

if ((${#missing_packages[@]} > 0)); then
  info "Устанавливаю только недостающие зависимости: ${missing_packages[*]}"
  apt-get update
  apt-get install -y "${missing_packages[@]}"
else
  info "Все зависимости уже установлены; apt пропускаю."
fi

require_cmd openvpn
require_cmd openssl
require_cmd iptables
require_cmd flock
require_cmd systemctl
require_cmd modprobe
require_cmd ss

systemctl cat "openvpn-server@$SERVER_NAME.service" >/dev/null 2>&1 ||
  die "Не найден systemd template openvpn-server@.service. Этот installer рассчитан на Debian/Proxmox layout."

ovpn_version="$(openvpn --version | awk 'NR==1 {print $2}')"
ovpn_major="${ovpn_version%%.*}"
ovpn_rest="${ovpn_version#*.}"
ovpn_minor="${ovpn_rest%%.*}"
[[ "$ovpn_major" =~ ^[0-9]+$ && "$ovpn_minor" =~ ^[0-9]+$ ]] ||
  die "Не удалось разобрать версию OpenVPN: $ovpn_version"
ovpn_major=$((10#$ovpn_major))
ovpn_minor=$((10#$ovpn_minor))
if (( ovpn_major < 2 || (ovpn_major == 2 && ovpn_minor < 6) )); then
  die "Нужен OpenVPN 2.6+, найден $ovpn_version."
fi

modprobe tun || true
[[ -c /dev/net/tun ]] || die "/dev/net/tun недоступен. Проверь kernel/module tun."

managed_conf="$SERVER_DIR/$SERVER_NAME.conf"
managed_instance=0
if systemctl is-active --quiet "openvpn-server@$SERVER_NAME.service" &&
   [[ -f "$managed_conf" && ! -L "$managed_conf" ]] &&
   grep -Fq '# Generated by pve-openvpn-kit.' "$managed_conf"; then
  managed_instance=1
fi

if [[ "$PROTO" == "udp" ]]; then
  listeners="$(ss -H -lunp "sport = :$PORT" 2>/dev/null || true)"
else
  listeners="$(ss -H -ltnp "sport = :$PORT" 2>/dev/null || true)"
fi
if [[ -n "$listeners" ]]; then
  foreign_listeners="$(printf '%s\n' "$listeners" | grep -vi 'openvpn' || true)"
  if [[ -n "$foreign_listeners" ]]; then
    echo "$foreign_listeners" >&2
    die "${PROTO^^}/$PORT занят процессом, который не относится к OpenVPN."
  fi

  if (( ! managed_instance )); then
    echo "$listeners" >&2
    die "${PROTO^^}/$PORT уже занят неизвестным OpenVPN instance. Не пытаюсь его перехватить."
  fi
fi

if ip link show "$TUN_IF" >/dev/null 2>&1 && (( ! managed_instance )); then
  die "Интерфейс $TUN_IF уже существует и не принадлежит активному instance этого набора."
fi

# Serialize every persistent change with management commands and uninstall.
acquire_pki_lock

update_tooling_only initial

info "Подготавливаю Easy-RSA..."
if [[ -e "$EASYRSA_DIR" ]]; then
  require_secure_root_dir "$EASYRSA_DIR"
  [[ -f "$EASYRSA_DIR/easyrsa" && ! -L "$EASYRSA_DIR/easyrsa" && -x "$EASYRSA_DIR/easyrsa" ]] ||
    die "Существующий $EASYRSA_DIR неполон или небезопасен: easyrsa должен быть regular executable."
  [[ "$(stat -c '%u' "$EASYRSA_DIR/easyrsa")" == "0" ]] ||
    die "$EASYRSA_DIR/easyrsa должен принадлежать root."
else
  install -d -o root -g root -m 0700 "$EASYRSA_DIR"
  cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
fi
chmod 0700 "$EASYRSA_DIR" "$EASYRSA_DIR/easyrsa"

if [[ -e "$EASYRSA_PKI_DIR" ]]; then
  require_secure_root_dir "$EASYRSA_PKI_DIR"
else
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa init-pki
  )
fi

for pki_subdir in private reqs issued tls-crypt-v2-clients secret-scrubbed; do
  path="$EASYRSA_PKI_DIR/$pki_subdir"
  if [[ -e "$path" ]]; then
    require_secure_root_dir "$path"
  fi
done
if [[ -e "$EASYRSA_PKI_DIR/vars" ]]; then
  [[ -f "$EASYRSA_PKI_DIR/vars" && ! -L "$EASYRSA_PKI_DIR/vars" ]] ||
    die "PKI vars должен быть regular file, не symlink."
fi
install -d -o root -g root -m 0700 \
  "$EASYRSA_PKI_DIR" \
  "$EASYRSA_PKI_DIR/tls-crypt-v2-clients" \
  "$EASYRSA_PKI_DIR/secret-scrubbed"
[[ ! -d "$EASYRSA_PKI_DIR/private" ]] || chmod 0700 "$EASYRSA_PKI_DIR/private"
[[ ! -d "$EASYRSA_PKI_DIR/reqs" ]] || chmod 0700 "$EASYRSA_PKI_DIR/reqs"
[[ ! -f "$EASYRSA_PKI_DIR/vars" ]] || chmod 0600 "$EASYRSA_PKI_DIR/vars"

# Настройки новой PKI. Существующий vars не перезаписываем.
if [[ ! -e "$EASYRSA_PKI_DIR/vars" ]]; then
  cat > "$EASYRSA_PKI_DIR/vars" <<EOF
# Managed defaults created by pve-openvpn-kit.
set_var EASYRSA_DN "cn_only"
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 825
set_var EASYRSA_CRL_DAYS $CRL_DAYS
set_var EASYRSA_RAND_SN "yes"
EOF

  inline_control_found=0
  if grep -Fq 'EASYRSA_DISABLE_INLINE' "$EASYRSA_DIR/easyrsa"; then
    printf '%s\n' 'set_var EASYRSA_DISABLE_INLINE 1' >> "$EASYRSA_PKI_DIR/vars"
    inline_control_found=1
  fi
  if grep -Fq 'EASYRSA_NO_INLINE' "$EASYRSA_DIR/easyrsa"; then
    printf '%s\n' 'set_var EASYRSA_NO_INLINE 1' >> "$EASYRSA_PKI_DIR/vars"
    inline_control_found=1
  fi
  (( inline_control_found )) ||
    die "Установленная версия Easy-RSA не содержит известного параметра отключения inline private files."

  chmod 0600 "$EASYRSA_PKI_DIR/vars"
fi

ca_crt="$EASYRSA_PKI_DIR/ca.crt"
ca_key="$EASYRSA_PKI_DIR/private/ca.key"

if [[ -e "$ca_crt" || -e "$ca_key" ]]; then
  [[ -f "$ca_crt" && ! -L "$ca_crt" && -f "$ca_key" && ! -L "$ca_key" ]] ||
    die "CA cert/key должны быть regular files, не symlink."
  [[ -s "$ca_crt" && -s "$ca_key" ]] ||
    die "PKI CA находится в частично созданном состоянии. Не продолжаю автоматически."
else
  if (( CA_NOPASS )); then
    info "Создаю CA без passphrase (явно выбранный режим)..."
    (
      cd "$EASYRSA_DIR"
      EASYRSA_BATCH=1 EASYRSA_REQ_CN="PVE OpenVPN CA" ./easyrsa build-ca nopass
    )
  else
    [[ -t 0 ]] ||
      die "Для защищённого CA требуется интерактивный терминал. Запусти install.sh из TTY или явно выбери --ca-nopass."
    info "Создаю защищённый CA. Easy-RSA попросит пароль и Common Name."
    echo "Рекомендуемый Common Name: PVE OpenVPN CA"
    (
      cd "$EASYRSA_DIR"
      ./easyrsa build-ca
    )
  fi
fi

[[ -s "$ca_crt" && -s "$ca_key" ]] || die "CA не создан."
openssl x509 -in "$ca_crt" -noout -checkend 0 >/dev/null 2>&1 ||
  die "CA certificate повреждён, ещё не действителен или истёк."
if private_key_is_unencrypted "$ca_key"; then
  ca_cert_pub="$(openssl x509 -in "$ca_crt" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  ca_key_pub="$(openssl pkey -in "$ca_key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$ca_cert_pub" && "$ca_cert_pub" == "$ca_key_pub" ]] ||
    die "CA certificate и незашифрованный private key не соответствуют друг другу."
fi

server_crt="$EASYRSA_PKI_DIR/issued/$SERVER_NAME.crt"
server_key="$EASYRSA_PKI_DIR/private/$SERVER_NAME.key"

if [[ -e "$server_crt" || -e "$server_key" ]]; then
  [[ -f "$server_crt" && ! -L "$server_crt" && -f "$server_key" && ! -L "$server_key" ]] ||
    die "Серверный cert/key должны быть regular files, не symlink."
  [[ -s "$server_crt" && -s "$server_key" ]] ||
    die "Серверный cert/key находятся в частично созданном состоянии."
else
  if ! private_key_is_unencrypted "$ca_key" && [[ ! -t 0 ]]; then
    die "CA требует passphrase; для выпуска server cert нужен интерактивный TTY."
  fi
  info "Создаю server certificate..."
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa build-server-full "$SERVER_NAME" nopass
  )
fi

[[ -s "$server_crt" && -s "$server_key" ]] || die "Server certificate/key не созданы."
[[ "$(pki_client_status "$SERVER_NAME" 2>/dev/null || true)" == "V" ]] ||
  die "Server certificate не отмечен active/valid в Easy-RSA index."
openssl x509 -in "$server_crt" -noout -checkhost "$SERVER_NAME" >/dev/null 2>&1 ||
  die "Server certificate identity не соответствует '$SERVER_NAME'."

# Easy-RSA обычно создаёт private material с безопасными правами; на повторном
# запуске принудительно исправляем их, если права были ослаблены вручную.
[[ ! -d "$EASYRSA_PKI_DIR/private" ]] || chmod 0700 "$EASYRSA_PKI_DIR/private"
find "$EASYRSA_PKI_DIR/private" -maxdepth 1 -type f -exec chmod 0600 {} + 2>/dev/null || true
find "$EASYRSA_PKI_DIR/tls-crypt-v2-clients" -maxdepth 1 -type f -exec chmod 0600 {} + 2>/dev/null || true

openssl verify -purpose sslserver -CAfile "$ca_crt" "$server_crt" >/dev/null ||
  die "Server certificate не проходит проверку CA/назначения/срока."

cert_pub="$(
  openssl x509 -in "$server_crt" -pubkey -noout |
  openssl pkey -pubin -outform DER 2>/dev/null |
  sha256sum | awk '{print $1}'
)"
key_pub="$(
  openssl pkey -in "$server_key" -pubout -outform DER 2>/dev/null |
  sha256sum | awk '{print $1}'
)"
[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] ||
  die "Server certificate и private key не соответствуют друг другу."

need_crl=0
crl_is_healthy "$EASYRSA_PKI_DIR/crl.pem" "$ca_crt" || need_crl=1

if (( need_crl )); then
  if ! private_key_is_unencrypted "$ca_key" && [[ ! -t 0 ]]; then
    die "CRL отсутствует/истёк, а CA требует passphrase. Запусти установщик из интерактивного TTY."
  fi
  info "Создаю/обновляю CRL..."
  (
    cd "$EASYRSA_DIR"
    EASYRSA_CRL_DAYS="$CRL_DAYS" EASYRSA_BATCH=1 ./easyrsa gen-crl
  )
fi

[[ -f "$EASYRSA_PKI_DIR/crl.pem" && ! -L "$EASYRSA_PKI_DIR/crl.pem" ]] ||
  die "CRL должен быть regular file, не symlink."
crl_is_healthy "$EASYRSA_PKI_DIR/crl.pem" "$ca_crt" ||
  die "CRL отсутствует, истёк, повреждён или подписан другой CA."

info "Устанавливаю server-side PKI..."
if [[ -e "$SERVER_DIR" ]]; then
  require_secure_root_dir "$SERVER_DIR"
fi
install -d -o root -g root -m 0755 "$SERVER_DIR"

for dest in ca.crt server.crt server.key crl.pem; do
  target="$SERVER_DIR/$dest"
  [[ ! -e "$target" || ( -f "$target" && ! -L "$target" ) ]] ||
    die "Не перезаписываю небезопасный server PKI path: $target"
done

install -o root -g root -m 0644 "$ca_crt" "$SERVER_DIR/ca.crt"
install -o root -g root -m 0644 "$server_crt" "$SERVER_DIR/server.crt"
install -o root -g root -m 0600 "$server_key" "$SERVER_DIR/server.key"
install -o root -g root -m 0644 "$EASYRSA_PKI_DIR/crl.pem" "$SERVER_DIR/crl.pem"

tls_v2_server_key="$SERVER_DIR/tls-crypt-v2-server.key"
if [[ -e "$tls_v2_server_key" && ( ! -f "$tls_v2_server_key" || -L "$tls_v2_server_key" ) ]]; then
  die "$tls_v2_server_key должен быть regular file, не symlink."
fi
if [[ ! -s "$tls_v2_server_key" ]]; then
  info "Создаю tls-crypt-v2 server key..."
  tmp_tls="$(mktemp "$SERVER_DIR/.tls-crypt-v2-server.XXXXXX")"
  trap 'rm -f "${tmp_tls:-}"' EXIT
  openvpn --genkey tls-crypt-v2-server "$tmp_tls"
  chmod 0600 "$tmp_tls"
  mv -f -- "$tmp_tls" "$tls_v2_server_key"
  tmp_tls=""
  trap - EXIT
fi
chmod 0600 "$tls_v2_server_key"

if [[ -e "$CLIENT_DIR" ]]; then
  require_secure_root_dir "$CLIENT_DIR"
fi
install -d -o root -g root -m 0700 "$CLIENT_DIR"

info "Записываю $CONFIG_FILE..."
tmp_config="$(mktemp /etc/openvpn/.pve-openvpn.conf.XXXXXX)"
trap 'rm -f "${tmp_config:-}"' EXIT
{
  printf '# Managed by pve-openvpn-kit; shell assignments, mode 0600.\n'
  printf 'OVPN_ENDPOINT=%q\n' "$ENDPOINT"
  printf 'OVPN_PORT=%q\n' "$PORT"
  printf 'OVPN_PROTO=%q\n' "$PROTO"
  printf 'OVPN_WAN_IF=%q\n' "$WAN_IF"
  printf 'OVPN_VPN_CIDR=%q\n' "$VPN_CIDR"
  printf 'OVPN_MODE=%q\n' "$MODE"
  printf 'OVPN_TUN_IF=%q\n' "$TUN_IF"
  printf 'OVPN_SERVER_NAME=%q\n' "$SERVER_NAME"
  printf 'OVPN_CLIENT_DIR=%q\n' "$CLIENT_DIR"
  printf 'OVPN_MAX_CLIENTS=%q\n' "$MAX_CLIENTS"
  printf 'OVPN_TLS_CRYPT_V2_COOKIE=%q\n' "$TLS_COOKIE"
  printf 'OVPN_CRL_DAYS=%q\n' "$CRL_DAYS"

  printf 'OVPN_LANS=('
  for lan in "${LANS[@]}"; do printf ' %q' "$lan"; done
  printf ' )\n'

  printf 'OVPN_DNS=('
  for dns in "${DNS_SERVERS[@]}"; do printf ' %q' "$dns"; done
  printf ' )\n'
} > "$tmp_config"
chmod 0600 "$tmp_config"
mv -f -- "$tmp_config" "$CONFIG_FILE"
tmp_config=""
trap - EXIT

info "Включаю IPv4 forwarding..."
if [[ -e /etc/sysctl.d/99-pve-openvpn.conf ]]; then
  [[ -f /etc/sysctl.d/99-pve-openvpn.conf && ! -L /etc/sysctl.d/99-pve-openvpn.conf ]] ||
    die "Не перезаписываю небезопасный /etc/sysctl.d/99-pve-openvpn.conf."
  grep -Fqx '# Managed by pve-openvpn-kit' /etc/sysctl.d/99-pve-openvpn.conf ||
    die "Не перезаписываю чужой /etc/sysctl.d/99-pve-openvpn.conf."
fi
cat > /etc/sysctl.d/99-pve-openvpn.conf <<'EOF'
# Managed by pve-openvpn-kit
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null
sysctl -w net.ipv4.ip_forward=1 >/dev/null
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] ||
  die "Не удалось включить net.ipv4.ip_forward."

/usr/local/lib/pve-openvpn/pve-openvpn-render-server

info "Устанавливаю systemd integration..."
unit_file=/etc/systemd/system/pve-openvpn-fw.service
if [[ -e "$unit_file" ]]; then
  [[ -f "$unit_file" && ! -L "$unit_file" ]] || die "Не перезаписываю небезопасный $unit_file."
  grep -Fqx 'Description=PVE OpenVPN forwarding/NAT rules' "$unit_file" ||
    die "Не перезаписываю чужой $unit_file."
fi
cat > "$unit_file" <<'EOF'
# Managed by pve-openvpn-kit
[Unit]
Description=PVE OpenVPN forwarding/NAT rules
Wants=network-online.target
After=network-online.target pve-firewall.service proxmox-firewall.service
Before=openvpn-server@server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=/usr/local/lib/pve-openvpn/pve-openvpn-fw up
ExecReload=/usr/local/lib/pve-openvpn/pve-openvpn-fw up
ExecStop=/usr/local/lib/pve-openvpn/pve-openvpn-fw down

[Install]
WantedBy=multi-user.target
EOF

dropin_dir="/etc/systemd/system/openvpn-server@$SERVER_NAME.service.d"
dropin_file="$dropin_dir/10-pve-openvpn-security.conf"
if [[ -e "$dropin_dir" || -L "$dropin_dir" ]]; then
  require_secure_root_dir "$dropin_dir"
fi
if [[ -e "$dropin_file" ]]; then
  [[ -f "$dropin_file" && ! -L "$dropin_file" ]] || die "Не перезаписываю небезопасный $dropin_file."
  grep -Fqx 'Requires=pve-openvpn-fw.service' "$dropin_file" || die "Не перезаписываю чужой $dropin_file."
fi
install -d -o root -g root -m 0755 "$dropin_dir"
cat > "$dropin_file" <<EOF
# Managed by pve-openvpn-kit
[Unit]
Requires=pve-openvpn-fw.service
After=pve-openvpn-fw.service

[Service]
# Fail closed: OpenVPN must not start without CRL/key material.
ExecStartPre=/usr/bin/test -s $SERVER_DIR/ca.crt
ExecStartPre=/usr/bin/test -s $SERVER_DIR/server.crt
ExecStartPre=/usr/bin/test -s $SERVER_DIR/server.key
ExecStartPre=/usr/bin/test -s $SERVER_DIR/crl.pem
ExecStartPre=/usr/bin/test -s $SERVER_DIR/tls-crypt-v2-server.key
EOF

systemctl daemon-reload
systemctl enable pve-openvpn-fw.service "openvpn-server@$SERVER_NAME.service"

if ! systemctl restart pve-openvpn-fw.service; then
  die "Не удалось применить forwarding/NAT. Проверь: journalctl -u pve-openvpn-fw"
fi

if ! systemctl restart "openvpn-server@$SERVER_NAME.service"; then
  journalctl -u "openvpn-server@$SERVER_NAME.service" -n 50 --no-pager >&2 || true
  die "OpenVPN не запустился. Смотри журнал выше."
fi

echo
info "OpenVPN установлен и запущен."
echo
echo "Проверка:"
echo "  ovpn-status"
echo
echo "Управление:"
echo "  ovpn   # интерактивное меню"
echo
echo "Профили:"
echo "  $CLIENT_DIR/*.ovpn"
echo
echo "ВАЖНО:"
echo "  * если сервер за NAT — пробрось ${PROTO^^}/$PORT на IP Proxmox;"
echo "  * если включён PVE Firewall — разреши ${PROTO^^}/$PORT штатным правилом PVE;"
echo "  * для доступа к GUI/SSH через VPN разреши нужные host INPUT-порты от $VPN_CIDR;"
echo "  * реальные PKI/private keys не храни в git."
