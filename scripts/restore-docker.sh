#!/bin/bash

BACKUP_ROOT="./backups"
PROJECT_NAME=$(basename "$(pwd)")

echo "=== Docker Project Restore ==="
echo "Проект: $PROJECT_NAME"
echo "=================================================="

# Автоматически выбираем самый свежий бэкап
LATEST_BACKUP=$(ls -1 "$BACKUP_ROOT/$PROJECT_NAME/" 2>/dev/null | sort -r | head -n 1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "❌ Ошибка: Бэкапы не найдены в $BACKUP_ROOT/$PROJECT_NAME/"
    exit 1
fi

echo "Самый свежий бэкап: $LATEST_BACKUP"
read -p "Восстановить этот бэкап? (Y/n): " confirm

if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Доступные бэкапы:"
    ls -1 "$BACKUP_ROOT/$PROJECT_NAME/" | sort -r
    read -p "Введите имя папки бэкапа: " BACKUP_DATE
else
    BACKUP_DATE="$LATEST_BACKUP"
fi

BACKUP_DIR="$BACKUP_ROOT/$PROJECT_NAME/$BACKUP_DATE"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ Ошибка: Папка бэкапа $BACKUP_DIR не найдена!"
    exit 1
fi

echo "Восстанавливаем из: $BACKUP_DIR"
echo "=================================================="

# Предупреждение
read -p "⚠️  Остановить все контейнеры проекта перед восстановлением? (Y/n): " stop_confirm
if [[ ! "$stop_confirm" =~ ^[Nn]$ ]]; then
    echo "🛑 Останавливаем контейнеры..."
    docker compose down --remove-orphans
fi

# 1. Восстановление Bind Mounts
echo "→ Восстанавливаем Bind Mounts (локальные папки):"
for file in "$BACKUP_DIR"/bind_*.tar.gz; do
    if [ -f "$file" ]; then
        folder=$(basename "$file" .tar.gz | sed 's/^bind_//')
        echo "   • ./$folder"
        mkdir -p "./$folder"

        # Очищаем перед восстановлением
        rm -rf "./$folder"/*

        tar -xzf "$file" -C "./$folder" --strip-components=1 2>/dev/null && \
        echo "     ✓ Восстановлено" || echo "     [!] Ошибка восстановления $folder"
    fi
done

# 2. Восстановление Named Volumes
echo "→ Восстанавливаем Named Volumes:"
for file in "$BACKUP_DIR"/volume_*.tar.gz; do
    if [ -f "$file" ]; then
        vol_name=$(basename "$file" .tar.gz | sed 's/^volume_//')
        echo "   • Volume: $vol_name"

        docker volume create "$vol_name" >/dev/null 2>&1 || true

        docker run --rm \
            -v "$vol_name":/data \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine:3.18 sh -c "rm -rf /data/* 2>/dev/null && tar -xzf /backup/$(basename "$file") -C /data" && \
        echo "     ✓ Восстановлено" || echo "     [!] Ошибка восстановления $vol_name"
    fi
done

# 3. Загрузка Images
echo "→ Загружаем Docker Images:"
for file in "$BACKUP_DIR"/image_*.tar; do
    if [ -f "$file" ]; then
        echo "   • $(basename "$file")"
        docker load -i "$file" >/dev/null 2>&1 && echo "     ✓ Загружен" || echo "     [!] Ошибка загрузки"
    fi
done

# 4. Конфиги
echo "→ Восстанавливаем конфиги..."
cp -f "$BACKUP_DIR/docker-compose.yml" ./ 2>/dev/null && echo "   ✓ docker-compose.yml"
[ -f "$BACKUP_DIR/.env" ] && cp -f "$BACKUP_DIR/.env" ./ 2>/dev/null && echo "   ✓ .env"

echo "=================================================="
echo "✅ Восстановление завершено!"
echo ""
echo "Рекомендуется выполнить:"
echo "   docker compose up -d"
