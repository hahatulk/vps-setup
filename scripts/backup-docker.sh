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
# 1. Bind Mounts
# =============================================
echo "→ Бэкапим Bind Mounts:"

BIND_COUNT=0

while IFS= read -r line; do
    host_path=$(echo "$line" | sed 's/^[ \t-]*//' | cut -d':' -f1)
    # убираем лишние пробелы без xargs
    host_path="${host_path#"${host_path%%[![:space:]]*}"}"
    host_path="${host_path%"${host_path##*[![:space:]]}"}"

    if [[ -n "$host_path" && -d "$host_path" ]]; then
        BIND_COUNT=$((BIND_COUNT + 1))
        name=$(basename "$host_path")
        echo "   • $host_path → bind_${name}.tar.gz"
        tar -czf "$BACKUP_DIR/bind_${name}.tar.gz" -C "$(dirname "$host_path")" "$name" || echo "     [!] Ошибка"
    fi
done < <(grep -E '^\s+-\s' docker-compose.yml 2>/dev/null | grep ':')

echo "   Найдено bind mounts: $BIND_COUNT"

# =============================================
# 2. Named Volumes (универсально)
# =============================================
echo "→ Бэкапим Named Volumes:"

VOLUME_COUNT=0

for vol in $(docker compose config --volumes 2>/dev/null); do
    if [[ -n "$vol" ]]; then
        # Ищем реальное имя volume (с префиксом проекта или без)
        REAL_VOL=$(docker volume ls -q | grep -E "(^|_)${vol}$" | head -n 1)

        if [[ -z "$REAL_VOL" ]]; then
            REAL_VOL="$vol"
        fi

        VOLUME_COUNT=$((VOLUME_COUNT + 1))
        echo "   • Volume: $vol → $REAL_VOL"

        BACKUP_FILE="$BACKUP_DIR/volume_${vol}_backup.tar.gz"

        docker run --rm \
          -v "${REAL_VOL}:/volume_data:ro" \
          -v "$(pwd)/$BACKUP_DIR:/backup" \
          alpine tar czf "/backup/volume_${vol}_backup.tar.gz" -C /volume_data . || \
          echo "     [!] Ошибка бэкапа $REAL_VOL"

        size=$(du -sh "$BACKUP_FILE" 2>/dev/null | awk '{print $1}' || echo "0")
        echo "     ✓ $size"
    fi
done

if [ "$VOLUME_COUNT" -eq 0 ]; then
    echo "   Named volumes не найдены"
else
    echo "   Всего named volumes: $VOLUME_COUNT"
fi

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
