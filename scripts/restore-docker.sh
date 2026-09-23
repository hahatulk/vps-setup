#!/usr/bin/env bash
set -u

BACKUP_ROOT="./backups"
PROJECT_NAME=$(basename "$(pwd)")

echo "=== Docker Project Restore ==="
echo "Проект: $PROJECT_NAME"
echo "=================================================="

# Выбираем самый свежий бэкап
LATEST_BACKUP=$(ls -1 "$BACKUP_ROOT/$PROJECT_NAME/" 2>/dev/null | sort -r | head -n 1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "❌ Бэкапы не найдены в $BACKUP_ROOT/$PROJECT_NAME/"
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

if [[ -z "$BACKUP_DATE" || "$BACKUP_DATE" == */* || "$BACKUP_DATE" == "." || "$BACKUP_DATE" == ".." ]]; then
    echo "❌ Некорректное имя бэкапа"
    exit 1
fi
BACKUP_DIR="$BACKUP_ROOT/$PROJECT_NAME/$BACKUP_DATE"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ Папка бэкапа $BACKUP_DIR не найдена!"
    exit 1
fi

# Имя compose из бэкапа или из текущей папки
SAVED_COMPOSE=""
[ -f "$BACKUP_DIR/.compose_filename" ] && SAVED_COMPOSE=$(cat "$BACKUP_DIR/.compose_filename")

DEFAULT_COMPOSE="$SAVED_COMPOSE"
if [[ -z "$DEFAULT_COMPOSE" ]]; then
    for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
        if [[ -f "$f" || -f "$BACKUP_DIR/$f" ]]; then
            DEFAULT_COMPOSE="$f"
            break
        fi
    done
fi

echo
echo "Compose-файлы в бэкапе:"
ls -1 "$BACKUP_DIR"/*.yml "$BACKUP_DIR"/*.yaml 2>/dev/null || echo "  (нет)"
echo

if [[ -n "$DEFAULT_COMPOSE" ]]; then
    read -p "Имя compose-файла [$DEFAULT_COMPOSE]: " COMPOSE
    COMPOSE="${COMPOSE:-$DEFAULT_COMPOSE}"
else
    read -p "Имя compose-файла: " COMPOSE
fi

if [[ -z "$COMPOSE" || "$COMPOSE" == */* || "$COMPOSE" == "." || "$COMPOSE" == ".." ]]; then
    echo "❌ Некорректное имя compose-файла"
    exit 1
fi

DC=(docker compose -f "$COMPOSE")

echo "Восстанавливаем из: $BACKUP_DIR"
echo "Compose: $COMPOSE"
echo "=================================================="

read -rp "Остановить контейнеры и начать разрушительное восстановление? Введите RESTORE: " stop_confirm
if [ "$stop_confirm" != "RESTORE" ]; then
    echo "Восстановление отменено."
    exit 0
else
    echo "🛑 Останавливаем контейнеры..."
    if [[ -f "$COMPOSE" ]]; then
        "${DC[@]}" stop
    else
        docker compose stop 2>/dev/null || true
    fi
fi

# =============================================
# 1. Восстановление Bind Mounts
# =============================================
echo "→ Восстанавливаем Bind Mounts:"

for file in "$BACKUP_DIR"/bind_*.tar.gz; do
    if [ -f "$file" ]; then
        folder=$(basename "$file" .tar.gz | sed 's/^bind_//')
        if [[ -z "$folder" || "$folder" == "." || "$folder" == ".." || "$folder" == */* ]]; then
            echo "   [!] Некорректное имя bind mount; пропуск"
            continue
        fi
        if [ -L "./$folder" ]; then
            echo "   [!] Целевой путь является символьной ссылкой; пропуск"
            continue
        fi
        echo "   • ./$folder"

        if ! tar -tzf "$file" >/dev/null 2>&1 || tar -tzf "$file" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
            echo "     [!] Небезопасный или повреждённый архив; пропуск"
            continue
        fi
        restore_tmp=$(mktemp -d)
        if tar -xzf "$file" -C "$restore_tmp" --strip-components=1; then
            mkdir -p "./$folder"
            find "./$folder" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
            cp -a "$restore_tmp"/. "./$folder"/
            echo "     ✓ Восстановлено"
        else
            echo "     [!] Ошибка восстановления $folder"
        fi
        rm -rf "$restore_tmp"
    fi
done

# =============================================
# 2. Восстановление Named Volumes
# =============================================
echo "→ Восстанавливаем Named Volumes:"

for file in "$BACKUP_DIR"/volume_*_backup.tar.gz; do
    if [ -f "$file" ]; then
        # Из имени файла достаём короткое имя volume (vw-data)
        vol=$(basename "$file" .tar.gz)
        vol=${vol#volume_}          # убираем volume_
        vol=${vol%_backup}          # убираем _backup

        if [[ ! "$vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || ! tar -tzf "$file" >/dev/null 2>&1 || tar -tzf "$file" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
            echo "   [!] Некорректный volume или архив; пропуск: $vol"
            continue
        fi

        # Сначала ищем существующий volume с этим именем (с префиксом или без)
        REAL_VOL=$(docker volume ls -q | awk -v vol="$vol" -v suffix="_$vol" '$0 == vol || substr($0, length($0)-length(suffix)+1) == suffix { print; exit }')

        # Если не нашли — создаём с префиксом проекта
        if [[ -z "$REAL_VOL" ]]; then
            REAL_VOL="${PROJECT_NAME}_${vol}"
            echo "   • Создаём volume: $REAL_VOL"
            docker volume create "$REAL_VOL" >/dev/null
        else
            echo "   • Используем существующий volume: $REAL_VOL"
        fi

        echo "   • Восстанавливаем $vol → $REAL_VOL"

        docker run --rm \
          -v "${REAL_VOL}:/data" \
          -v "$(pwd)/$BACKUP_DIR:/backup:ro" \
          alpine sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar xzf "/backup/$1" -C /data' sh "$(basename "$file")" && \
        echo "     ✓ Восстановлено" || echo "     [!] Ошибка восстановления $vol"
    fi
done

# =============================================
# 3. Загрузка Images
# =============================================
echo "→ Загружаем Images:"

for file in "$BACKUP_DIR"/image_*.tar; do
    if [ -f "$file" ]; then
        echo "   • $(basename "$file")"
        docker load -i "$file" >/dev/null 2>&1 && echo "     ✓ Загружен" || echo "     [!] Ошибка загрузки"
    fi
done

# =============================================
# 4. Конфиги
# =============================================
echo "→ Восстанавливаем конфиги..."

# Сначала целевое имя из настроек, иначе любой compose из бэкапа
if [ -f "$BACKUP_DIR/$COMPOSE" ]; then
    cp -f "$BACKUP_DIR/$COMPOSE" "./$COMPOSE" && echo "   ✓ $COMPOSE"
elif [ -n "$SAVED_COMPOSE" ] && [ -f "$BACKUP_DIR/$SAVED_COMPOSE" ]; then
    cp -f "$BACKUP_DIR/$SAVED_COMPOSE" "./$COMPOSE" && echo "   ✓ $COMPOSE (из $SAVED_COMPOSE)"
else
    found=""
    for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
        if [ -f "$BACKUP_DIR/$f" ]; then
            cp -f "$BACKUP_DIR/$f" "./$COMPOSE" && echo "   ✓ $COMPOSE (из $f)"
            found=1
            break
        fi
    done
    [ -z "$found" ] && echo "   [!] Compose-файл в бэкапе не найден"
fi

[ -f "$BACKUP_DIR/.env" ] && cp -f "$BACKUP_DIR/.env" ./ && echo "   ✓ .env"

echo "=================================================="
echo "✅ Восстановление завершено!"
echo ""
