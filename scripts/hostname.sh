#!/usr/bin/env bash
set -euo pipefail

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите скрипт от root"
    exit 1
fi

# Получаем новое имя
NEW_HOSTNAME="${1:-}"

if [[ -z "$NEW_HOSTNAME" ]]; then
    read -rp "Введите новое имя сервера: " NEW_HOSTNAME
fi

# Проверка имени
if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Ошибка: некорректное имя сервера"
    exit 1
fi

OLD_HOSTNAME=$(hostname)

echo "Старое имя: $OLD_HOSTNAME"
echo "Новое имя: $NEW_HOSTNAME"

# Меняем hostname
hostnamectl set-hostname "$NEW_HOSTNAME"

# Обновляем /etc/hosts
if grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E \
        "s/^[[:space:]]*127\.0\.1\.1[[:space:]].*/127.0.1.1 $NEW_HOSTNAME/" \
        /etc/hosts
else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi

# Защита от сброса hostname через cloud-init
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    cat > /etc/cloud/cloud.cfg.d/99-local-hostname.cfg <<EOF
#cloud-config
preserve_hostname: true
manage_etc_hosts: false
EOF
fi

echo ""
echo "Hostname успешно изменён!"
echo "Текущее имя: $(hostname)"
echo "Переподключитесь по SSH для обновления приглашения."