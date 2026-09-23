#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Скрипт должен быть запущен с правами root (используйте sudo)."
  exit 1
fi
if ! command -v iptables >/dev/null 2>&1; then
  echo "Ошибка: iptables не установлен."
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'
if ! tput setaf 1 >/dev/null 2>&1; then
  RED='' GREEN='' BLUE='' YELLOW='' NC=''
fi

CURRENT_IP=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')
if [ -z "$CURRENT_IP" ]; then
  CURRENT_IP=$(who | awk '{print $5}' | head -n1 | tr -d '()')
fi

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && \
  [ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ]
}

valid_cidr() {
  local net mask
  [[ "$1" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]{1,2})$ ]] || return 1
  net="${BASH_REMATCH[1]}"
  mask="${BASH_REMATCH[2]}"
  valid_ip "$net" && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]
}

valid_target() { valid_ip "$1" || valid_cidr "$1"; }

ip_in_net() {
  local ip="$1" target="$2" net mask ipi neti
  if valid_ip "$target"; then
    [ "$ip" = "$target" ]; return
  fi
  valid_cidr "$target" || return 1
  net="${target%/*}"; mask="${target#*/}"
  [ "$mask" -eq 0 ] && return 0
  ipi=$(ip2int "$ip"); neti=$(ip2int "$net")
  [ $(( ipi >> (32 - mask) )) -eq $(( neti >> (32 - mask) )) ]
}

is_self() {
  [ -n "$CURRENT_IP" ] && valid_ip "$CURRENT_IP" && ip_in_net "$CURRENT_IP" "$1"
}

already_blocked() {
  iptables -C INPUT -s "$1" -j DROP 2>/dev/null
}

show_blocked_ips() {
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Список заблокированных IP/подсетей ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  temp_file=$(mktemp)
  iptables -L INPUT -v -n --line-numbers | awk '
    /DROP/ && $4 == "DROP" && $9 != "0.0.0.0/0" && $9 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/ {
      print $1, $9
    }
  ' > "$temp_file"
  if [ -s "$temp_file" ]; then
    while read -r line_num ip; do
      echo -e "${GREEN} Правило №$line_num: $ip${NC}"
    done < "$temp_file"
  else
    echo -e "${YELLOW} Нет заблокированных IP/подсетей.${NC}"
  fi
  rm -f "$temp_file"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

do_block() {
  local ip="$1"
  if ! valid_target "$ip"; then
    echo -e "${RED}Пропуск: неверный формат — $ip${NC}"
    return 1
  fi
  if is_self "$ip"; then
    echo -e "${RED}Пропуск: это ваш IP/подсеть ($CURRENT_IP) — $ip${NC}"
    return 1
  fi
  if already_blocked "$ip"; then
    echo -e "${YELLOW}Уже заблокирован: $ip${NC}"
    return 0
  fi
  iptables -A INPUT -s "$ip" -j DROP
  echo -e "${GREEN}Заблокирован: $ip${NC}"
}

do_unblock() {
  local ip="$1"
  if ! valid_target "$ip"; then
    echo -e "${RED}Пропуск: неверный формат — $ip${NC}"
    return 1
  fi
  if already_blocked "$ip"; then
    iptables -D INPUT -s "$ip" -j DROP
    echo -e "${GREEN}Разблокирован: $ip${NC}"
  else
    echo -e "${YELLOW}Не найден в правилах: $ip${NC}"
  fi
}

read_list_file() {
  local src="$1" tmp
  [ -z "$src" ] && read -p "Путь к файлу или URL: " src
  if [[ "$src" =~ ^https?:// ]]; then
    tmp=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
      curl --connect-timeout 10 --max-time 60 -fsSL "$src" -o "$tmp" || { echo -e "${RED}Не скачалось: $src${NC}"; rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget --timeout=60 -qO "$tmp" "$src" || { echo -e "${RED}Не скачалось: $src${NC}"; rm -f "$tmp"; return 1; }
    else
      echo -e "${RED}Нужен curl или wget.${NC}"
      return 1
    fi
    echo "$tmp"
    return 0
  fi
  if [ ! -f "$src" ] || [ ! -r "$src" ]; then
    echo -e "${RED}Файл недоступен: $src${NC}"
    return 1
  fi
  echo "$src"
}

process_file() {
  local action="$1" source="${2:-}" file line n=0 downloaded=0
  [ -z "$source" ] && read -rp "Путь к файлу или URL: " source
  [[ "$source" =~ ^https?:// ]] && downloaded=1
  file=$(read_list_file "$source") || return
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    n=$((n + 1))
    if [ "$action" = block ]; then
      do_block "$line"
    else
      do_unblock "$line"
    fi
  done < "$file"
  [ "$downloaded" -eq 1 ] && rm -f "$file"
  echo -e "${BLUE}Обработано строк: $n${NC}"
}

block_ip() {
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Блокировка IP / подсети            ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  read -p "IP или подсеть: " ip
  do_block "$ip"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

unblock_ip() {
  show_blocked_ips
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Разблокировка                      ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}1 — по номеру правила  2 — по IP/подсети${NC}"
  read -p "Способ: " how
  if [ "$how" = "2" ]; then
    read -p "IP или подсеть: " ip
    do_unblock "$ip"
  else
    read -p "Номер правила: " rule_num
    if echo "$rule_num" | grep -E '^[0-9]+$' >/dev/null; then
      if iptables -L INPUT --line-numbers | grep -q "^$rule_num "; then
        iptables -D INPUT "$rule_num"
        echo -e "${GREEN}Правило №$rule_num удалено.${NC}"
      else
        echo -e "${RED}Правила №$rule_num нет.${NC}"
      fi
    else
      echo -e "${RED}Введите номер правила.${NC}"
    fi
  fi
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

while true; do
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo -e "${YELLOW} Меню управления блокировкой IP ${NC}"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo -e "${GREEN}1. Показать заблокированные${NC}"
  echo -e "${GREEN}2. Заблокировать IP/подсеть${NC}"
  echo -e "${GREEN}3. Разблокировать${NC}"
  echo -e "${GREEN}4. Заблокировать из файла/URL${NC}"
  echo -e "${GREEN}5. Разблокировать из файла/URL${NC}"
  echo -e "${GREEN}6. Выход${NC}"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  read -p "Выберите действие (1-6): " choice
  case $choice in
    1) show_blocked_ips ;;
    2) block_ip ;;
    3) unblock_ip ;;
    4)
      echo -e "${BLUE}Блокировка из файла/URL${NC}"
      process_file block
      ;;
    5)
      echo -e "${BLUE}Разблокировка из файла/URL${NC}"
      process_file unblock
      ;;
    6)
      echo -e "${GREEN}Выход из скрипта.${NC}"
      exit 0
      ;;
    *) echo -e "${RED}Неверный выбор.${NC}" ;;
  esac
done
