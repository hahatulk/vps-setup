#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ENDPOINT=""
PORT="1194"
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

assert_managed_file_or_absent() {
  local file="$1" marker="$2"
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -f "$file" && ! -L "$file" ]] || die "Не перезаписываю небезопасный $file."
  grep -Fq "$marker" "$file" || die "Не перезаписываю чужой $file."
}

usage() {
  cat <<'EOF'
Установка OpenVPN для Proxmox VE 9 / Debian 13.

Использование:
  ./install.sh --endpoint HOST_OR_IP [опции]

Обязательное:
  --endpoint HOST_OR_IP     Публичный IPv4 или DNS-имя VPN-сервера.

Опции:
  --port PORT               UDP-порт (по умолчанию 1194).
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

[[ -n "$ENDPOINT" ]] || die "Укажи --endpoint PUBLIC_IP_OR_DNS."
validate_endpoint "$ENDPOINT"

[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "Некорректный порт: $PORT"
PORT=$((10#$PORT))
(( PORT >= 1 && PORT <= 65535 )) || die "Некорректный порт: $PORT"
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
echo "  Endpoint:       $ENDPOINT:$PORT/udp"
echo "  WAN:            $WAN_IF"
echo "  VPN subnet:     $VPN_CIDR"
echo "  Mode:           $MODE"
echo "  Max clients:    $MAX_CLIENTS"
echo "  LAN routes:     ${LANS[*]:-(нет)}"
echo "  DNS(full):      ${DNS_SERVERS[*]:-(нет)}"
echo "  tls-crypt-v2:   $TLS_COOKIE"
if (( CA_NOPASS )); then
  warn "CA private key будет БЕЗ пароля (--ca-nopass)."
else
  echo "  CA key:         password protected"
fi
echo

if [[ "$MODE" == "full" ]]; then
  warn "Full-tunnel в этом наборе — IPv4. IPv6 клиента не туннелируется; см. SECURITY.md."
fi

# Fail before package/PKI changes rather than overwrite files owned by another setup.
assert_managed_file_or_absent "$CONFIG_FILE" 'OVPN_ENDPOINT='
assert_managed_file_or_absent "$SERVER_DIR/$SERVER_NAME.conf" '# Generated by pve-openvpn-kit.'
assert_managed_file_or_absent /etc/sysctl.d/99-pve-openvpn.conf '# Managed by pve-openvpn-kit'
assert_managed_file_or_absent /etc/systemd/system/pve-openvpn-fw.service 'Description=PVE OpenVPN forwarding/NAT rules'
assert_managed_file_or_absent "/etc/systemd/system/openvpn-server@$SERVER_NAME.service.d/10-pve-openvpn-security.conf" 'Requires=pve-openvpn-fw.service'

export DEBIAN_FRONTEND=noninteractive
info "Устанавливаю зависимости..."
apt-get update
apt-get install -y   openvpn   easy-rsa   iptables   ca-certificates   openssl   util-linux   iproute2   kmod

require_cmd openvpn
require_cmd openssl
require_cmd iptables
require_cmd flock
require_cmd systemctl
require_cmd modprobe

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

listeners="$(ss -H -lunp "sport = :$PORT" 2>/dev/null || true)"
if [[ -n "$listeners" && "$listeners" != *openvpn* ]]; then
  echo "$listeners" >&2
  die "UDP/$PORT уже занят другим процессом. Выбери другой --port или освободи порт."
fi

# Serialize every persistent change with management commands and uninstall.
acquire_pki_lock
acquire_config_lock

info "Устанавливаю управляющие команды..."
if [[ -e /usr/local/lib/pve-openvpn ]]; then
  [[ -d /usr/local/lib/pve-openvpn && ! -L /usr/local/lib/pve-openvpn ]] ||
    die "/usr/local/lib/pve-openvpn должен быть каталогом, не symlink."
fi
for target in /usr/local/lib/pve-openvpn/common.sh /usr/local/lib/pve-openvpn/verify-crl-health; do
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || die "Не перезаписываю небезопасный $target."
    if [[ "$target" == */common.sh ]]; then
      grep -Fq 'CONFIG_FILE="/etc/openvpn/pve-openvpn.conf"' "$target" || die "Не перезаписываю чужой $target."
    else
      grep -Fq 'CRL="/etc/openvpn/server/crl.pem"' "$target" || die "Не перезаписываю чужой $target."
    fi
  fi
done
for f in "$SCRIPT_DIR"/bin/*; do
  target="/usr/local/sbin/$(basename "$f")"
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || die "Не перезаписываю небезопасный $target."
    grep -Fq '/usr/local/lib/pve-openvpn/common.sh' "$target" ||
      die "Не перезаписываю чужую команду $target. Удали/переименуй её вручную."
  fi
done
install -d -m 0755 /usr/local/lib/pve-openvpn /usr/local/sbin
install -m 0644 "$SCRIPT_DIR/lib/common.sh" /usr/local/lib/pve-openvpn/common.sh
install -m 0755 "$SCRIPT_DIR/lib/verify-crl-health" /usr/local/lib/pve-openvpn/verify-crl-health
for f in "$SCRIPT_DIR"/bin/*; do
  install -m 0755 "$f" "/usr/local/sbin/$(basename "$f")"
done

info "Подготавливаю Easy-RSA..."
if [[ -e "$EASYRSA_DIR" ]]; then
  [[ -d "$EASYRSA_DIR" && ! -L "$EASYRSA_DIR" ]] ||
    die "$EASYRSA_DIR должен быть настоящим каталогом, не symlink."
  [[ -x "$EASYRSA_DIR/easyrsa" ]] ||
    die "Существующий $EASYRSA_DIR неполон: easyrsa отсутствует. Не перезаписываю каталог автоматически."
else
  install -d -m 0700 "$EASYRSA_DIR"
  cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
fi
chmod 0700 "$EASYRSA_DIR" "$EASYRSA_DIR/easyrsa"

if [[ -e "$EASYRSA_PKI_DIR" ]]; then
  [[ -d "$EASYRSA_PKI_DIR" && ! -L "$EASYRSA_PKI_DIR" ]] ||
    die "$EASYRSA_PKI_DIR должен быть каталогом, не symlink."
else
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa init-pki
  )
fi

for pki_subdir in private reqs issued tls-crypt-v2-clients secret-scrubbed; do
  path="$EASYRSA_PKI_DIR/$pki_subdir"
  [[ ! -e "$path" || ( -d "$path" && ! -L "$path" ) ]] ||
    die "Небезопасный PKI subdirectory: $path"
done
if [[ -e "$EASYRSA_PKI_DIR/vars" ]]; then
  [[ -f "$EASYRSA_PKI_DIR/vars" && ! -L "$EASYRSA_PKI_DIR/vars" ]] ||
    die "PKI vars должен быть regular file, не symlink."
fi
install -d -m 0700   "$EASYRSA_PKI_DIR"   "$EASYRSA_PKI_DIR/tls-crypt-v2-clients"   "$EASYRSA_PKI_DIR/secret-scrubbed"
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
set_var EASYRSA_DISABLE_INLINE 1
EOF
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
  [[ -d "$SERVER_DIR" && ! -L "$SERVER_DIR" ]] || die "$SERVER_DIR должен быть каталогом, не symlink."
fi
install -d -m 0755 "$SERVER_DIR"
install -m 0644 "$ca_crt" "$SERVER_DIR/ca.crt"
install -m 0644 "$server_crt" "$SERVER_DIR/server.crt"
install -m 0600 "$server_key" "$SERVER_DIR/server.key"
install -m 0644 "$EASYRSA_PKI_DIR/crl.pem" "$SERVER_DIR/crl.pem"

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
  [[ -d "$CLIENT_DIR" && ! -L "$CLIENT_DIR" ]] || die "$CLIENT_DIR должен быть каталогом, не symlink."
fi
install -d -m 0700 "$CLIENT_DIR"

info "Записываю $CONFIG_FILE..."
tmp_config="$(mktemp /etc/openvpn/.pve-openvpn.conf.XXXXXX)"
trap 'rm -f "${tmp_config:-}"' EXIT
{
  printf '# Managed by pve-openvpn-kit; shell assignments, mode 0600.\n'
  printf 'OVPN_ENDPOINT=%q\n' "$ENDPOINT"
  printf 'OVPN_PORT=%q\n' "$PORT"
  printf 'OVPN_PROTO=%q\n' "udp"
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

/usr/local/sbin/ovpn-render-server

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
After=network-online.target
Before=openvpn-server@server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=/usr/local/sbin/ovpn-fw up
ExecReload=/usr/local/sbin/ovpn-fw up
ExecStop=/usr/local/sbin/ovpn-fw down

[Install]
WantedBy=multi-user.target
EOF

dropin_dir="/etc/systemd/system/openvpn-server@$SERVER_NAME.service.d"
dropin_file="$dropin_dir/10-pve-openvpn-security.conf"
if [[ -e "$dropin_dir" ]]; then
  [[ -d "$dropin_dir" && ! -L "$dropin_dir" ]] || die "Не использую небезопасный $dropin_dir."
fi
if [[ -e "$dropin_file" ]]; then
  [[ -f "$dropin_file" && ! -L "$dropin_file" ]] || die "Не перезаписываю небезопасный $dropin_file."
  grep -Fqx 'Requires=pve-openvpn-fw.service' "$dropin_file" || die "Не перезаписываю чужой $dropin_file."
fi
install -d -m 0755 "$dropin_dir"
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
echo "Создать клиента:"
echo "  ovpn-add-client laptop"
echo
echo "Профили:"
echo "  $CLIENT_DIR/*.ovpn"
echo
echo "ВАЖНО:"
echo "  * если сервер за NAT — пробрось UDP/$PORT на IP Proxmox;"
echo "  * если включён PVE Firewall — разреши UDP/$PORT штатным правилом PVE;"
echo "  * для доступа к GUI/SSH через VPN разреши нужные host INPUT-порты от $VPN_CIDR;"
echo "  * реальные PKI/private keys не храни в git."
