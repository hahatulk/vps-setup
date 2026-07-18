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

BIND_COUNT=0

# Способ 1: docker compose config
while IFS= read -r line; do
    host_path=$(echo "$line" | sed 's/^[[:space:]]*-*[[:space:]]*//' | cut -d':' -f1 | xargs -r)
    if [[ -n "$host_path" && -d "$host_path" ]]; then
        BIND_COUNT=$((BIND_COUNT + 1))
        folder_name=$(basename "$host_path")
        echo "   • $host_path → bind_${folder_name}.tar.gz"
        tar -czf "$BACKUP_DIR/bind_${folder_name}.tar.gz" -C "$(dirname "$host_path")" "$folder_name" || \
        echo "     [!] Ошибка бэкапа $host_path"
    fi
done < <(docker compose config 2>/dev/null | grep -E '^\s+-\s' | grep ':')

# Способ 2: Прямой парсинг yml (если первый не сработал)
if [[ $BIND_COUNT -eq 0 ]]; then
    echo "   Пробуем прямой парсинг docker-compose.yml..."
    while IFS= read -r line; do
        host_path=$(echo "$line" | sed 's/^[[:space:]]*-*[[:space:]]*//' | cut -d':' -f1 | xargs -r)
        if [[ -n "$host_path" && -d "$host_path" ]]; then
            BIND_COUNT=$((BIND_COUNT + 1))
            folder_name=$(basename "$host_path")
            echo "   • $host_path → bind_${folder_name}.tar.gz"
            tar -czf "$BACKUP_DIR/bind_${folder_name}.tar.gz" -C "$(dirname "$host_path")" "$folder_name" || \
            echo "     [!] Ошибка бэкапа $host_path"
        fi
    done < <(grep -E '^\s+-\s' docker-compose.yml | grep ':')
fi

echo "   Найдено bind mounts: $BIND_COUNT"

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
    if [ -n "$image" ] && [ "$image" != "null" ]; then
        safe_name=$(echo "$image" | tr '/:' '_')
        echo "   • $image"
        docker pull "$image" >/dev/null 2>&1 || true
        docker save "$image" -o "$BACKUP_DIR/image_${safe_name}.tar"
        size=$(du -sh "$BACKUP_DIR/image_${safe_name}.tar" 2>/dev/null | awk '{print $1}')
        echo "     ✓ $size"
    fi
done

# =============================================
# 4. Конфиги
# =============================================
echo "→ Копируем конфиги..."
cp docker-compose.yml "$BACKUP_DIR/" 2>/dev/null || true
[ -f ".env" ] && cp .env "$BACKUP_DIR/" 2>/dev/null || true

echo "=================================================="
echo "✅ Бэкап завершён!"
echo "Размер: $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
ls -lh "$BACKUP_DIR"
