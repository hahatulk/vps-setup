#!/usr/bin/env bash
set -u

PROJECT_NAME=$(basename "$(pwd)")
DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_DIR="./backups/$PROJECT_NAME/$DATE"

echo "=== Полный Docker Backup ==="
echo "Проект: $PROJECT_NAME"

# Ищем стандартные файлы, чтобы подсказать дефолт
DEFAULT_COMPOSE=""
for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    if [[ -f "$f" ]]; then
        DEFAULT_COMPOSE="$f"
        break
    fi
done

echo "Найденные compose-файлы:"
ls -1 compose.yml compose.yaml docker-compose.yml docker-compose.yaml *.yml *.yaml 2>/dev/null | sort -u
echo

if [[ -n "$DEFAULT_COMPOSE" ]]; then
    read -p "Имя compose-файла [$DEFAULT_COMPOSE]: " COMPOSE
    COMPOSE="${COMPOSE:-$DEFAULT_COMPOSE}"
else
    read -p "Имя compose-файла: " COMPOSE
fi

if [[ -z "$COMPOSE" || ! -f "$COMPOSE" ]]; then
    echo "❌ Файл '$COMPOSE' не найден"
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
        if [ -e "$BACKUP_DIR/bind_${name}.tar.gz" ]; then
            echo "     [!] Совпадающее имя bind mount; пропуск во избежание перезаписи"
            continue
        fi
        if tar -czf "$BACKUP_DIR/bind_${name}.tar.gz" --exclude='./backups' --exclude="$name/backups" -C "$(dirname "$host_path")" "$name"; then
            :
        else
            rm -f "$BACKUP_DIR/bind_${name}.tar.gz"
            echo "     [!] Ошибка"
        fi
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
        if [[ ! "$vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            echo "     [!] Небезопасное имя volume; пропуск: $vol"
            continue
        fi
        REAL_VOL=$(docker volume ls -q | awk -v vol="$vol" -v suffix="_$vol" '$0 == vol || substr($0, length($0)-length(suffix)+1) == suffix { print; exit }')
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
echo "$COMPOSE" > "$BACKUP_DIR/.compose_filename"
[ -f ".env" ] && cp .env "$BACKUP_DIR/" 2>/dev/null || true

echo "=================================================="
echo "✅ Бэкап завершён!"
echo "Размер: $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
ls -lh "$BACKUP_DIR"
