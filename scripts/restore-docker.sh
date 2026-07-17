#!/bin/bash

BACKUP_ROOT="./backups"
PROJECT_NAME=$(basename "$(pwd)")

echo "=== Docker Project Restore ==="
echo "Проект: $PROJECT_NAME"
echo "=================================================="

# Автоматически выбираем самый свежий бэкап
LATEST_BACKUP=$(ls -1 "$BACKUP_ROOT/$PROJECT_NAME/" 2>/dev/null | sort | tail -n 1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "Ошибка: Бэкапы не найдены!"
    exit 1
fi

echo "Самый свежий бэкап: $LATEST_BACKUP"
read -p "Восстановить этот бэкап? (Y/n): " confirm

if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Доступные бэкапы:"
    ls "$BACKUP_ROOT/$PROJECT_NAME/"
    BACKUP_DATE="$LATEST_BACKUP"
    read -p "Введите дату бэкапа: " BACKUP_DATE
else
    BACKUP_DATE="$LATEST_BACKUP"
fi

BACKUP_DIR="$BACKUP_ROOT/$PROJECT_NAME/$BACKUP_DATE"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Ошибка: Папка бэкапа не найдена!"
    exit 1
fi

echo "Восстанавливаем из: $BACKUP_DIR"
echo "=================================================="

# 1. Восстановление Bind Mounts (локальные папки)
echo "→ Восстанавливаем Bind Mounts (локальные папки):"
for file in "$BACKUP_DIR"/bind_*.tar.gz; do
    if [ -f "$file" ]; then
        folder=$(basename "$file" .tar.gz | sed 's/bind_//')
        echo "   • ./$folder"
        mkdir -p "./$folder"
        tar -xzf "$file" -C . --strip-components=1 2>/dev/null && \
        echo "     ✓ Восстановлено" || echo "     [!] Ошибка восстановления $folder"
    fi
done

# 2. Восстановление Named Volumes
echo "→ Восстанавливаем Named Volumes:"
for file in "$BACKUP_DIR"/volume_*.tar.gz; do
    if [ -f "$file" ]; then
        vol_name=$(basename "$file" .tar.gz | sed 's/volume_//')
        echo "   • Volume: $vol_name"

        docker volume create "$vol_name" >/dev/null 2>&1
        docker run --rm \
            -v "$vol_name":/data \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine:3.18 \
            sh -c "rm -rf /data/* 2>/dev/null && tar -xzf /backup/$(basename "$file") -C /data" && \
        echo "     ✓ Восстановлено" || echo "     [!] Ошибка $vol_name"
    fi
done

# 3. Загрузка Images
echo "→ Загружаем Images:"
for file in "$BACKUP_DIR"/image_*.tar; do
    if [ -f "$file" ]; then
        echo "   • $(basename "$file")"
        docker load -i "$file" >/dev/null 2>&1 && echo "     ✓ Загружен" || echo "     [!] Ошибка"
    fi
done

# 4. Конфиги
echo "→ Восстанавливаем конфиги..."
cp "$BACKUP_DIR/docker-compose.yml" ./ 2>/dev/null
[ -f "$BACKUP_DIR/.env" ] && cp "$BACKUP_DIR/.env" ./ 2>/dev/null

echo "=================================================="
echo "✅ Восстановление завершено!"
echo "Рекомендую выполнить:"
echo "   docker compose down"
echo "   docker compose up -d"
