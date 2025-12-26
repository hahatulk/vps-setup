#!/bin/bash

# Проверка, что скрипт запущен от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Скрипт должен быть запущен с правами root (используйте sudo)."
  exit 1
fi

# Проверка наличия iptables
if ! command -v iptables >/dev/null 2>&1; then
  echo "Ошибка: iptables не установлен. Установите его с помощью 'sudo apt install iptables' или аналогичной команды."
  exit 1
fi

# Цвета для форматирования вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
# Проверка поддержки цветов
if ! tput setaf 1 >/dev/null 2>&1; then
  RED='' GREEN='' BLUE='' YELLOW='' NC='' # Отключаем цвета, если терминал не поддерживает
fi

# Получение текущего IP клиента (например, через SSH)
CURRENT_IP=$(who am i | awk '{print $5}' | tr -d '()')
if [ -z "$CURRENT_IP" ]; then
  CURRENT_IP=$(who | awk '{print $5}' | head -n1)
fi

# Функция для отображения текущих заблокированных IP
show_blocked_ips() {
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Список заблокированных IP-адресов  ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  
  temp_file=$(mktemp)
  iptables -L INPUT -v -n --line-numbers | awk '
    /DROP/ && $4 == "DROP" && $9 != "0.0.0.0/0" && $9 ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/ {
      print $1, $9
    }
  ' > "$temp_file"
  
  if [ -s "$temp_file" ]; then
    while read -r line_num ip; do
      echo -e "${GREEN}  Правило №$line_num: IP $ip${NC}"
    done < "$temp_file"
  else
    echo -e "${YELLOW}  Нет заблокированных IP-адресов.${NC}"
  fi
  
  rm -f "$temp_file"
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

# Функция для блокировки IP
block_ip() {
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Блокировка IP-адреса               ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  read -p "Введите IP-адрес (например, 192.168.1.100): " ip
  if echo "$ip" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' >/dev/null; then
    if [ "$ip" = "$CURRENT_IP" ]; then
      echo -e "${RED}Ошибка: Нельзя заблокировать ваш текущий IP ($CURRENT_IP)!${NC}"
    else
      iptables -A INPUT -s "$ip" -j DROP
      echo -e "${GREEN}IP $ip успешно заблокирован.${NC}"
    fi
  else
    echo -e "${RED}Ошибка: Неверный формат IP-адреса.${NC}"
  fi
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

# Функция для разблокировки IP
unblock_ip() {
  show_blocked_ips
  echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ Разблокировка IP-адреса            ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
  read -p "Введите номер правила для разблокировки: " rule_num
  if echo "$rule_num" | grep -E '^[0-9]+$' >/dev/null; then
    if iptables -L INPUT --line-numbers | grep -q "^$rule_num "; then
      iptables -D INPUT "$rule_num"
      echo -e "${GREEN}Правило №$rule_num успешно удалено.${NC}"
    else
      echo -e "${RED}Ошибка: Правила с номером $rule_num не существует.${NC}"
    fi
  else
    echo -e "${RED}Ошибка: Введите корректный номер правила.${NC}"
  fi
  echo -e "${BLUE}══════════════════════════════════════${NC}"
}

# Основное меню
while true; do
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo -e "${YELLOW}      Меню управления блокировкой IP   ${NC}"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  echo -e "${GREEN}1. Показать заблокированные IP${NC}"
  echo -e "${GREEN}2. Заблокировать IP${NC}"
  echo -e "${GREEN}3. Разблокировать IP${NC}"
  echo -e "${GREEN}4. Выход${NC}"
  echo -e "${YELLOW}══════════════════════════════════════${NC}"
  read -p "Выберите действие (1-4): " choice

  case $choice in
    1)
      show_blocked_ips
      ;;
    2)
      block_ip
      ;;
    3)
      unblock_ip
      ;;
    4)
      echo -e "${YELLOW}══════════════════════════════════════${NC}"
      echo -e "${GREEN}Выход из скрипта.${NC}"
      echo -e "${YELLOW}══════════════════════════════════════${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Ошибка: Неверный выбор. Попробуйте снова.${NC}"
      echo -e "${BLUE}══════════════════════════════════════${NC}"
      ;;
  esac
done