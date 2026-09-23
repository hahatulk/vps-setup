#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Easy-RSA changed the inline-control variable across 3.2.x releases.
# Export both names: 3.2.2 understands DISABLE_INLINE, newer releases use NO_INLINE.
export EASYRSA_DISABLE_INLINE=1
export EASYRSA_NO_INLINE=1

CONFIG_FILE="/etc/openvpn/pve-openvpn.conf"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
EASYRSA_PKI_DIR="$EASYRSA_DIR/pki"
# shellcheck disable=SC2034 # exported API used by scripts sourcing this library
SERVER_DIR="/etc/openvpn/server"
CLIENT_DIR_DEFAULT="/root/openvpn-clients"
SERVER_NAME_DEFAULT="server"
PKI_LOCK_DIR="/run/pve-openvpn"
PKI_LOCK_FILE="$PKI_LOCK_DIR/pki.lock"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти команду от root."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

require_interactive_tty() {
  [[ -t 0 && -t 1 ]] || die "Эта команда работает интерактивно и требует TTY/терминал."
}

prompt_nonempty() {
  local prompt="$1" value
  while true; do
    IFS= read -r -p "$prompt" value || die "Ввод прерван."
    [[ -n "$value" ]] || {
      warn "Значение не может быть пустым."
      continue
    }
    printf '%s\n' "$value"
    return 0
  done
}

prompt_with_default() {
  local prompt="$1" default="$2" value
  IFS= read -r -p "$prompt [$default]: " value || die "Ввод прерван."
  printf '%s\n' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1" default="${2:-no}" answer suffix
  case "$default" in
    yes) suffix="[Y/n]" ;;
    no) suffix="[y/N]" ;;
    *) die "Некорректный default для prompt_yes_no: $default" ;;
  esac

  while true; do
    IFS= read -r -p "$prompt $suffix: " answer || die "Ввод прерван."
    if [[ -z "$answer" ]]; then
      [[ "$default" == "yes" ]]
      return
    fi
    case "$answer" in
      y|Y|yes|YES|Yes|да|Да|ДА) return 0 ;;
      n|N|no|NO|No|нет|Нет|НЕТ) return 1 ;;
      *) warn "Ответь y/yes/да или n/no/нет." ;;
    esac
  done
}

pki_client_rows() {
  local index="$EASYRSA_PKI_DIR/index.txt"
  [[ -r "$index" ]] || return 1
  awk -F '\t' -v server_name="${OVPN_SERVER_NAME:-$SERVER_NAME_DEFAULT}" '
    {
      subject=$6
      cn=subject
      sub(/^.*CN=/, "", cn)
      sub(/\/.*/, "", cn)
      if (cn != "" && cn != server_name) {
        status=$1
        label=status
        if (status == "V") label="ACTIVE"
        else if (status == "R") label="REVOKED"
        else if (status == "E") label="EXPIRED"
        print cn "\t" status "\t" label
      }
    }
  ' "$index"
}

prompt_client_from_pki() {
  local allowed_statuses="${1:-V E R}" title="${2:-Выбери VPN-клиента:}"
  local -a names=() labels=()
  local cn status label token allowed i choice

  while IFS=$'\t' read -r cn status label; do
    [[ -n "$cn" ]] || continue
    allowed=0
    for token in $allowed_statuses; do
      [[ "$status" == "$token" ]] && allowed=1
    done
    (( allowed )) || continue
    names+=("$cn")
    labels+=("$label")
  done < <(pki_client_rows || true)

  ((${#names[@]} > 0)) || die "Подходящих клиентов в PKI не найдено."

  echo "$title" >&2
  for i in "${!names[@]}"; do
    printf '  %d) %-32s [%s]\n' "$((i + 1))" "${names[$i]}" "${labels[$i]}" >&2
  done
  echo "  0) Отмена" >&2

  while true; do
    IFS= read -r -p "Номер: " choice || die "Ввод прерван."
    [[ "$choice" =~ ^[0-9]+$ ]] || {
      warn "Введи номер из списка."
      continue
    }
    choice=$((10#$choice))
    (( choice == 0 )) && return 1
    if (( choice >= 1 && choice <= ${#names[@]} )); then
      printf '%s\n' "${names[$((choice - 1))]}"
      return 0
    fi
    warn "Нет такого пункта."
  done
}

acquire_pki_lock() {
  require_cmd flock
  if [[ -e "$PKI_LOCK_DIR" ]]; then
    [[ -d "$PKI_LOCK_DIR" && ! -L "$PKI_LOCK_DIR" ]] || die "Небезопасный lock directory: $PKI_LOCK_DIR"
    [[ "$(stat -c '%u:%a' "$PKI_LOCK_DIR")" == "0:700" ]] ||
      die "$PKI_LOCK_DIR должен принадлежать root и иметь mode 0700."
  else
    install -d -o root -g root -m 0700 "$PKI_LOCK_DIR"
  fi
  [[ ! -e "$PKI_LOCK_FILE" || ( -f "$PKI_LOCK_FILE" && ! -L "$PKI_LOCK_FILE" ) ]] ||
    die "Небезопасный PKI lock file: $PKI_LOCK_FILE"
  exec 9>"$PKI_LOCK_FILE"
  [[ "$(stat -c '%u' "$PKI_LOCK_FILE")" == "0" ]] || die "PKI lock file должен принадлежать root."
  chmod 0600 "$PKI_LOCK_FILE"
  flock -x -w 30 9 || die "PKI занята другой операцией (lock timeout 30s). Повтори позже."
}

secure_root_dir() {
  local dir="$1" owner mode mode_dec
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  owner="$(stat -c '%u' "$dir")" || return 1
  mode="$(stat -c '%a' "$dir")" || return 1
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_dec=$((8#$mode))
  # Group/other may read/traverse public directories, but must never write them.
  (( (mode_dec & 0022) == 0 ))
}

secure_root_file() {
  local file="$1" owner mode mode_dec
  [[ -f "$file" && ! -L "$file" ]] || return 1
  owner="$(stat -c '%u' "$file")" || return 1
  mode="$(stat -c '%a' "$file")" || return 1
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_dec=$((8#$mode))
  (( (mode_dec & 0022) == 0 ))
}

require_secure_root_dir() {
  local dir="$1"
  secure_root_dir "$dir" ||
    die "Каталог должен быть real directory, принадлежать root и не быть writable для group/other: $dir"
}

config_file_is_secure() {
  local file="${1:-$CONFIG_FILE}" owner mode mode_dec parent
  [[ -f "$file" && ! -L "$file" ]] || return 1
  parent="$(dirname -- "$file")"
  secure_root_dir "$parent" || return 1
  owner="$(stat -c '%u' "$file")" || return 1
  mode="$(stat -c '%a' "$file")" || return 1
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_dec=$((8#$mode))
  (( (mode_dec & 0077) == 0 ))
}

validate_safe_absolute_dir() {
  local path="$1"
  [[ "$path" == /* && "$path" != "/" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] ||
    die "Небезопасный абсолютный путь каталога: $path"
  [[ "/$path/" != *"/../"* && "/$path/" != *"/./"* ]] ||
    die "Путь каталога не должен содержать . или ..: $path"
}

load_config() {
  config_file_is_secure "$CONFIG_FILE" ||
    die "Не найден безопасный root-owned regular file 0600 $CONFIG_FILE. Сначала запусти install.sh."

  # Файл source-ится как shell assignments, поэтому перед этим жёстко проверяются owner/mode.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${OVPN_ENDPOINT:?}"
  : "${OVPN_PORT:?}"
  : "${OVPN_PROTO:?}"
  : "${OVPN_WAN_IF:?}"
  : "${OVPN_VPN_CIDR:?}"
  : "${OVPN_MODE:?}"

  OVPN_TUN_IF="${OVPN_TUN_IF:-tun0}"
  OVPN_SERVER_NAME="${OVPN_SERVER_NAME:-$SERVER_NAME_DEFAULT}"
  OVPN_CLIENT_DIR="${OVPN_CLIENT_DIR:-$CLIENT_DIR_DEFAULT}"
  OVPN_MAX_CLIENTS="${OVPN_MAX_CLIENTS:-64}"
  OVPN_TLS_CRYPT_V2_COOKIE="${OVPN_TLS_CRYPT_V2_COOKIE:-force-cookie}"
  OVPN_CRL_DAYS="${OVPN_CRL_DAYS:-3650}"

  declare -p OVPN_LANS >/dev/null 2>&1 || OVPN_LANS=()
  declare -p OVPN_DNS >/dev/null 2>&1 || OVPN_DNS=()

  validate_endpoint "$OVPN_ENDPOINT"
  [[ "$OVPN_PORT" =~ ^[0-9]{1,5}$ ]] || die "Некорректный OVPN_PORT в $CONFIG_FILE."
  (( 10#$OVPN_PORT >= 1 && 10#$OVPN_PORT <= 65535 )) || die "OVPN_PORT вне диапазона."
  [[ "$OVPN_PROTO" == "udp" ]] || die "Поддерживается только OVPN_PROTO=udp."
  [[ "$OVPN_MODE" == "split" || "$OVPN_MODE" == "full" ]] || die "Некорректный OVPN_MODE."
  [[ "$OVPN_WAN_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "Некорректный OVPN_WAN_IF."
  [[ "$OVPN_TUN_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "Некорректный OVPN_TUN_IF."
  [[ "$OVPN_SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die "Некорректный OVPN_SERVER_NAME."
  validate_safe_absolute_dir "$OVPN_CLIENT_DIR"
  if [[ -e "$OVPN_CLIENT_DIR" || -L "$OVPN_CLIENT_DIR" ]]; then
    require_secure_root_dir "$OVPN_CLIENT_DIR"
  fi
  [[ "$OVPN_MAX_CLIENTS" =~ ^[0-9]{1,4}$ ]] || die "Некорректный OVPN_MAX_CLIENTS."
  (( 10#$OVPN_MAX_CLIENTS >= 1 && 10#$OVPN_MAX_CLIENTS <= 4096 )) || die "OVPN_MAX_CLIENTS вне диапазона."
  [[ "$OVPN_TLS_CRYPT_V2_COOKIE" == "force-cookie" || "$OVPN_TLS_CRYPT_V2_COOKIE" == "allow-noncookie" ]] ||
    die "Некорректный OVPN_TLS_CRYPT_V2_COOKIE."
  [[ "$OVPN_CRL_DAYS" =~ ^[0-9]{1,5}$ ]] || die "Некорректный OVPN_CRL_DAYS."
  (( 10#$OVPN_CRL_DAYS >= 1 && 10#$OVPN_CRL_DAYS <= 36500 )) || die "OVPN_CRL_DAYS вне диапазона."
  OVPN_VPN_CIDR="$(normalize_cidr "$OVPN_VPN_CIDR")" || die "Некорректная VPN subnet."
  local vpn_prefix
  vpn_prefix="$(cidr_prefix "$OVPN_VPN_CIDR")" || die "Некорректный VPN prefix."
  (( vpn_prefix >= 8 && vpn_prefix <= 30 )) || die "VPN prefix должен быть /8../30."

  local lan dns
  for lan in "${OVPN_LANS[@]}"; do
    normalize_cidr "$lan" >/dev/null
    cidr_overlap "$OVPN_VPN_CIDR" "$lan" && die "OVPN_LANS пересекается с VPN subnet: $lan"
  done
  for dns in "${OVPN_DNS[@]}"; do
    validate_ipv4 "$dns"
  done
}

validate_client_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] ||
    die "Имя клиента: только A-Z, a-z, 0-9, ., _, -, максимум 64 символа."
  [[ "$name" != "$SERVER_NAME_DEFAULT" && "$name" != "${OVPN_SERVER_NAME:-$SERVER_NAME_DEFAULT}" && "$name" != ca ]] ||
    die "Имя CA/server зарезервировано: $name"
  [[ "$name" != "." && "$name" != ".." ]] || die "Недопустимое имя клиента."
}

ip_to_int() {
  local ip="$1" a b c d oct
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] ||
    die "Некорректный IPv4: $ip"
  IFS=. read -r a b c d <<<"$ip"
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] ||
    die "Некорректный IPv4: $ip"

  for oct in "$a" "$b" "$c" "$d"; do
    [[ "$oct" =~ ^[0-9]{1,3}$ ]] || die "Некорректный IPv4: $ip"
    (( 10#$oct >= 0 && 10#$oct <= 255 )) || die "Некорректный IPv4: $ip"
  done

  a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
  printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

validate_ipv4() {
  ip_to_int "$1" >/dev/null
}

validate_endpoint() {
  local value="$1" label
  [[ -n "$value" && ${#value} -le 253 ]] || die "Некорректный endpoint: $value"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *[[:space:]]* ]] ||
    die "Endpoint не должен содержать пробелы/переводы строк."

  if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    validate_ipv4 "$value"
    return
  fi

  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || die "Endpoint должен быть IPv4 или DNS-именем."
  [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] ||
    die "Некорректное DNS-имя endpoint: $value"

  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || die "Некорректная DNS-метка: $label"
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      die "Некорректная DNS-метка: $label"
  done
}

int_to_ip() {
  local n="$1"
  printf '%d.%d.%d.%d\n'     "$(( (n >> 24) & 255 ))"     "$(( (n >> 16) & 255 ))"     "$(( (n >> 8) & 255 ))"     "$(( n & 255 ))"
}

cidr_parts() {
  local cidr="$1" ip prefix ip_int mask_int network_int broadcast_int
  [[ "$cidr" == */* ]] || die "CIDR должен иметь вид 10.8.0.0/24: $cidr"
  ip="${cidr%/*}"
  prefix="${cidr#*/}"

  validate_ipv4 "$ip"
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || die "Некорректный IPv4 prefix /$prefix: $cidr"
  prefix=$((10#$prefix))
  (( prefix >= 0 && prefix <= 32 )) || die "Некорректный IPv4 prefix /$prefix: $cidr"

  ip_int="$(ip_to_int "$ip")"
  if (( prefix == 0 )); then
    mask_int=0
  else
    mask_int=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  network_int=$(( ip_int & mask_int ))
  broadcast_int=$(( network_int | ((~mask_int) & 0xFFFFFFFF) ))

  printf '%s %s %s %s %s\n'     "$(int_to_ip "$network_int")"     "$(int_to_ip "$mask_int")"     "$network_int"     "$broadcast_int"     "$prefix"
}

cidr_network_netmask() {
  local parts network mask _start _end _prefix
  parts="$(cidr_parts "$1")" || return 1
  read -r network mask _start _end _prefix <<<"$parts"
  printf '%s %s\n' "$network" "$mask"
}

cidr_network() {
  local parts network _rest
  parts="$(cidr_parts "$1")" || return 1
  read -r network _rest <<<"$parts"
  printf '%s\n' "$network"
}

cidr_prefix() {
  local parts _network _mask _start _end prefix
  parts="$(cidr_parts "$1")" || return 1
  read -r _network _mask _start _end prefix <<<"$parts"
  printf '%s\n' "$prefix"
}

normalize_cidr() {
  local parts network _mask _start _end prefix
  parts="$(cidr_parts "$1")" || return 1
  read -r network _mask _start _end prefix <<<"$parts"
  printf '%s/%s\n' "$network" "$prefix"
}

cidr_overlap() {
  local parts_a parts_b _n1 _m1 a_start a_end _p1
  local _n2 _m2 b_start b_end _p2
  parts_a="$(cidr_parts "$1")" || return 2
  parts_b="$(cidr_parts "$2")" || return 2
  read -r _n1 _m1 a_start a_end _p1 <<<"$parts_a"
  read -r _n2 _m2 b_start b_end _p2 <<<"$parts_b"
  (( a_start <= b_end && b_start <= a_end ))
}

private_key_is_unencrypted() {
  local key_file="$1"
  [[ -s "$key_file" ]] || return 1
  openssl pkey -in "$key_file" -noout -passin pass: >/dev/null 2>&1
}

crl_is_healthy() {
  local crl_file="$1" ca_file="${2:-}" next_update last_update next_epoch last_epoch now_epoch
  [[ -f "$crl_file" && ! -L "$crl_file" && -s "$crl_file" && -r "$crl_file" ]] || return 1
  openssl crl -in "$crl_file" -noout >/dev/null 2>&1 || return 1
  if [[ -n "$ca_file" ]]; then
    [[ -f "$ca_file" && ! -L "$ca_file" && -s "$ca_file" && -r "$ca_file" ]] || return 1
    openssl crl -in "$crl_file" -noout -verify -CAfile "$ca_file" >/dev/null 2>&1 || return 1
  fi
  next_update="$(openssl crl -in "$crl_file" -noout -nextupdate 2>/dev/null | sed -n 's/^nextUpdate=//p')"
  last_update="$(openssl crl -in "$crl_file" -noout -lastupdate 2>/dev/null | sed -n 's/^lastUpdate=//p')"
  [[ -n "$next_update" && -n "$last_update" ]] || return 1
  next_epoch="$(date -u -d "$next_update" +%s 2>/dev/null)" || return 1
  last_epoch="$(date -u -d "$last_update" +%s 2>/dev/null)" || return 1
  now_epoch="$(date -u +%s)" || return 1
  # Permit five minutes of clock skew, but reject CRLs issued in the future.
  (( next_epoch > now_epoch && last_epoch <= now_epoch + 300 ))
}

pki_client_status() {
  local name="$1" index="$EASYRSA_PKI_DIR/index.txt"
  [[ -r "$index" ]] || return 1

  awk -F '\t' -v target="$name" '
    {
      subject=$6
      cn=subject
      sub(/^.*CN=/, "", cn)
      sub(/\/.*/, "", cn)
      if (cn == target) status=$1
    }
    END {
      if (status != "") print status
      else exit 1
    }
  ' "$index"
}

iptables_cmd() {
  iptables -w 5 "$@"
}

iptables_add() {
  local table="$1"; shift
  if [[ "$table" == "filter" ]]; then
    iptables_cmd -C "$@" 2>/dev/null || iptables_cmd -A "$@"
  else
    iptables_cmd -t "$table" -C "$@" 2>/dev/null || iptables_cmd -t "$table" -A "$@"
  fi
}

iptables_del() {
  local table="$1"; shift
  if [[ "$table" == "filter" ]]; then
    while iptables_cmd -C "$@" 2>/dev/null; do iptables_cmd -D "$@"; done
  else
    while iptables_cmd -t "$table" -C "$@" 2>/dev/null; do iptables_cmd -t "$table" -D "$@"; done
  fi
}
