#!/bin/bash
set -euo pipefail

# =============================================
# Настройки
# =============================================
# Кастомное имя compose-файла.
# Можно указать относительный путь: compose.prod.yml
# или полный: /opt/app/docker-compose.custom.yml
# Пусто = автопоиск (compose.yml / compose.yaml / docker-compose.yml / docker-compose.yaml)
COMPOSE_FILE_NAME="docker-compose.yml"

PROJECT_NAME=$(basename "$(pwd)")
DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_DIR="./backups/$PROJECT_NAME/$DATE"

# --- определяем compose-файл ---
COMPOSE=""
if [[ -n "${COMPOSE_FILE_NAME:-}" && -f "$COMPOSE_FILE_NAME" ]]; then
    COMPOSE="$COMPOSE_FILE_NAME"
elif [[ -n "${COMPOSE_FILE:-}" ]]; then
    IFS=':' read -ra _cf <<< "$COMPOSE_FILE"
    for f in "${_cf[@]}"; do
        if [[ -f "$f" ]]; then
            COMPOSE="$f"
            break
        fi
    done
fi

if [[ -z "$COMPOSE" ]]; then
    for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
        if [[ -f "$f" ]]; then
            COMPOSE="$f"
            break
        fi
    done
fi

if [[ -z "$COMPOSE" || ! -f "$COMPOSE" ]]; then
    echo "❌ Compose-файл не найден. Задайте COMPOSE_FILE_NAME в начале скрипта."
    exit 1
fi

DC=(docker compose -f "$COMPOSE")

mkdir -p "$BACKUP_DIR"
echo "=== Полный Docker Backup ==="
echo "Проект: $PROJECT_NAME"
echo "Compose: $COMPOSE"
echo "Бэкап в: $BACKUP_DIR"
echo "=================================================="

# =============================================
# 1. Bind Mounts
# =============================================
echo "→ Бэкапим Bind Mounts:"
BIND_COUNT=0
while IFS= read -r line; do
    host_path=$(echo "$line" | sed 's/^[ \t-]*//' | cut -d':' -f1)
    host_path="${host_path#"${host_path%%[![:space:]]*}"}"
    host_path="${host_path%"${host_path##*[![:space:]]}"}"
    if [[ -n "$host_path" && -d "$host_path" ]]; then
        BIND_COUNT=$((BIND_COUNT + 1))
        name=$(basename "$host_path")
        echo "   • $host_path → bind_${name}.tar.gz"
        tar -czf "$BACKUP_DIR/bind_${name}.tar.gz" -C "$(dirname "$host_path")" "$name" || echo "     [!] Ошибка"
    fi
done < <(grep -E '^\s+-\s' "$COMPOSE" 2>/dev/null | grep ':')
echo "   Найдено bind mounts: $BIND_COUNT"

# =============================================
# 2. Named Volumes
# =============================================
echo "→ Бэкапим Named Volumes:"
VOLUME_COUNT=0
for vol in $("${DC[@]}" config --volumes 2>/dev/null); do
    if [[ -n "$vol" ]]; then
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
"${DC[@]}" config --images 2>/dev/null | sort | uniq | while read -r image; do
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
cp "$COMPOSE" "$BACKUP_DIR/" 2>/dev/null || true
[ -f ".env" ] && cp .env "$BACKUP_DIR/" 2>/dev/null || true

echo "=================================================="
echo "✅ Бэкап завершён!"
echo "Размер: $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
ls -lh "$BACKUP_DIR"
