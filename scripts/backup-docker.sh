#!/bin/bash

PROJECT_NAME=$(basename "$(pwd)")
DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_DIR="./backups/$PROJECT_NAME/$DATE"
mkdir -p "$BACKUP_DIR"

echo "=== Полный Docker Backup ==="
echo "Проект: $PROJECT_NAME"
echo "Бэкап в: $BACKUP_DIR"
echo "=================================================="

# =============================================
# 1. Bind Mounts — локальные папки
# =============================================
echo "→ Бэкапим Bind Mounts (локальные папки):"

# Основной способ — парсим docker compose config
docker compose config 2>/dev/null | grep -E '^\s+-\s' | grep ':' | while read -r line; do
    host_path=$(echo "$line" | awk -F: '{gsub(/^[ \t-]+/,"",$1); print $1}')
    if [ -n "$host_path" ] && [ -d "$host_path" ]; then
        folder_name=$(basename "$host_path")
        echo "   • $host_path  →  bind_${folder_name}.tar.gz"
        tar -czf "$BACKUP_DIR/bind_${folder_name}.tar.gz" -C "$(dirname "$host_path")" "$folder_name" || \
        echo "     [!] Ошибка бэкапа $host_path"
    fi
done

# Fallback — если выше ничего не нашёл
if [ -z "$(ls "$BACKUP_DIR"/bind_*.tar.gz 2>/dev/null)" ]; then
    echo "   Используем fallback поиск папок..."
    for dir in data db redis postgres uptime-kuma-data *.data; do
        if [ -d "./$dir" ]; then
            echo "   • ./$dir"
            tar -czf "$BACKUP_DIR/bind_${dir}.tar.gz" "./$dir"
        fi
    done
fi

# =============================================
# 2. Named Volumes
# =============================================
echo "→ Бэкапим Named Volumes:"
docker compose config --volumes 2>/dev/null | while read -r vol; do
    if [ -n "$vol" ]; then
        echo "   • Volume: $vol"
        docker run --rm \
            -v "$vol":/data:ro \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine:3.18 tar -czf "/backup/volume_${vol}.tar.gz" -C /data . || \
            echo "     [!] Не удалось volume $vol"
    fi
done

# =============================================
# 3. Images
# =============================================
echo "→ Бэкапим Images:"
docker compose config --images 2>/dev/null | sort | uniq | while read -r image; do
    if [ -n "$image" ]; then
        safe_name=$(echo "$image" | tr '/:' '_')
        echo "   • $image"
        docker pull "$image" >/dev/null 2>&1
        docker save "$image" -o "$BACKUP_DIR/image_${safe_name}.tar"
        size=$(du -sh "$BACKUP_DIR/image_${safe_name}.tar" 2>/dev/null | awk '{print $1}')
        echo "     ✓ $size"
    fi
done

# =============================================
# 4. Конфиги
# =============================================
cp docker-compose.yml "$BACKUP_DIR/" 2>/dev/null
[ -f ".env" ] && cp .env "$BACKUP_DIR/" 2>/dev/null

echo "=================================================="
echo "✅ Бэкап завершён!"
du -sh "$BACKUP_DIR"
ls -lh "$BACKUP_DIR"
