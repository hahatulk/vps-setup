#!/usr/bin/env bash
set -uo pipefail

# Keep this menu local: the script can be copied without other project files.
ITEM_KEYS=() ITEM_LABELS=() ITEM_REASONS=() ITEM_SELECTED=()
add_item() {
    ITEM_KEYS+=("$1"); ITEM_LABELS+=("$2"); ITEM_REASONS+=("${3:-}")
    if [[ -z "${3:-}" ]]; then ITEM_SELECTED+=(1); else ITEM_SELECTED+=(0); fi
}
select_items() {
    local title=$1 input i count output status
    local -a options=()
    while true; do
        if [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
            options=()
            local unavailable=''
            for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
                if [[ -n "${ITEM_REASONS[i]}" ]]; then
                    unavailable+=$'\n'"[!] ${ITEM_LABELS[i]}: ${ITEM_REASONS[i]}"
                else
                    status=OFF
                    [[ "${ITEM_SELECTED[i]}" -eq 0 ]] || status=ON
                    options+=("$((i+1))" "${ITEM_LABELS[i]}" "$status")
                fi
            done
            if [[ ${#options[@]} -eq 0 ]]; then
                printf '%s\nНет доступных пунктов.%s\n' "$title" "$unavailable"
                return 1
            fi
            output=$(whiptail --title "$title" --separate-output \
                --ok-button 'Начать' --cancel-button 'Отмена' \
                --checklist "Пробел — флажок. Tab — действия.${unavailable}" \
                20 76 8 "${options[@]}" 3>&1 1>&2 2>&3) || return 1
            for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do ITEM_SELECTED[i]=0; done
            while IFS= read -r input; do
                [[ -n "$input" ]] && ITEM_SELECTED[input-1]=1
            done <<< "$output"
        else
            printf '\n=== %s ===\n' "$title"
            for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
                if [[ -n "${ITEM_REASONS[i]}" ]]; then
                    printf ' %2d. [!] %s — недоступно: %s\n' "$((i+1))" "${ITEM_LABELS[i]}" "${ITEM_REASONS[i]}"
                elif [[ "${ITEM_SELECTED[i]}" -eq 1 ]]; then
                    printf ' %2d. [x] %s\n' "$((i+1))" "${ITEM_LABELS[i]}"
                else
                    printf ' %2d. [ ] %s\n' "$((i+1))" "${ITEM_LABELS[i]}"
                fi
            done
            echo 'Номера через пробел — переключить; a — все; n — снять все; s — начать; q — отмена.'
            read -rp '> ' input || return 1
            case "$input" in
                q|Q) return 1 ;;
                a|A|n|N)
                    for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
                        ITEM_SELECTED[i]=0
                        [[ "$input" == n || "$input" == N || -n "${ITEM_REASONS[i]}" ]] || ITEM_SELECTED[i]=1
                    done
                    continue ;;
                s|S) : ;;
                *)
                    for input in $input; do
                        if [[ "$input" =~ ^[0-9]{1,6}$ ]] && ((10#$input >= 1 && 10#$input <= ${#ITEM_KEYS[@]})); then
                            i=$((10#$input-1))
                            [[ -n "${ITEM_REASONS[i]}" ]] || ITEM_SELECTED[i]=$((1-ITEM_SELECTED[i]))
                        else
                            echo "Некорректный номер: $input"
                        fi
                    done
                    continue ;;
            esac
        fi
        count=0
        for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do ((count+=ITEM_SELECTED[i])); done
        [[ "$count" -eq 0 ]] || return 0
        echo 'Выберите хотя бы один пункт или отмените операцию.'
    done
}
selected() {
    local i
    for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
        [[ "${ITEM_KEYS[i]}" != "$1" ]] || [[ "${ITEM_SELECTED[i]}" -eq 0 ]] || return 0
    done
    return 1
}
fail() { echo "❌ $*" >&2; exit 1; }
restore_tmp=''
cleanup_restore_tmp() {
    if [[ -n "$restore_tmp" ]]; then rm -rf -- "$restore_tmp"; restore_tmp=''; fi
}
trap cleanup_restore_tmp EXIT
archive_safe() {
    local listing
    listing=$(tar -tzf "$1") || return 1
    ! printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))'
}
bind_destination_safe() {
    local destination
    [[ ! -L "$1" ]] || return 1
    destination=$(realpath -m -- "$1") || return 1
    [[ "$destination" != / && "$BACKUP_ABS" != "$destination" && "$BACKUP_ABS" != "$destination/"* ]]
}

paths_overlap() {
    local left right
    left=$(realpath -m -- "$1") || fail "Не удалось проверить путь: $1"
    right=$(realpath -m -- "$2") || fail "Не удалось проверить путь: $2"
    [[ "$left" == / || "$right" == / || "$left" == "$right" || "$left/" == "$right/"* || "$right/" == "$left/"* ]]
}
find_running_consumers() {
    local ids id records type source name extra file vol used
    ids=$(docker ps --quiet) || fail 'Не удалось проверить работающие контейнеры'
    for id in $ids; do
        [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || fail 'Некорректный ID контейнера'
        records=$(docker container inspect --format "$RUNNING_MOUNTS_TEMPLATE" "$id") || fail "Не удалось проверить mounts контейнера: $id"
        while IFS=$'\t' read -r type source name extra; do
            [[ -n "$type" ]] || continue
            [[ -n "$source" && -n "$name" && -z "$extra" ]] || fail 'Некорректное описание mount'
            used=0
            if [[ "$type" == volume ]]; then
                for file in "${VOLUME_FILES[@]}"; do
                    selected "volume:$file" || continue
                    vol=${file##*/}; vol=${vol#volume_}; vol=${vol%_backup.tar.gz}
                    [[ "${VOLUME_NAMES[$vol]}" != "$source" ]] || used=1
                done
            elif [[ "$type" == bind ]]; then
                for file in "${BIND_FILES[@]}"; do
                    selected "bind:$file" || continue
                    paths_overlap "${BIND_PATHS[${file##*/}]}" "$source" && used=1
                done
            fi
            if [[ "$used" -eq 1 ]]; then
                printf '%s\t%s\n' "$id" "$name"
                break
            fi
        done <<< "$records"
    done
}
require_stopped_destinations() {
    local remaining
    remaining=$(find_running_consumers) || fail 'Не удалось повторно проверить потребителей данных'
    [[ -z "$remaining" ]] || fail 'Данные всё ещё использует работающий контейнер; запись не начата'
}
RUNNING_MOUNTS_TEMPLATE='{{if .State.Running}}{{range .Mounts}}{{if eq .Type "volume"}}{{printf "volume\t%s\t%s\n" .Name $.Name}}{{else if eq .Type "bind"}}{{printf "bind\t%s\t%s\n" .Source $.Name}}{{end}}{{end}}{{end}}'

BACKUP_ROOT='./backups'
PROJECT_NAME=$(basename "$PWD")
echo "=== Docker Restore: $PROJECT_NAME ==="
LATEST_BACKUP=$(find "$BACKUP_ROOT/$PROJECT_NAME" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -n 1)
[[ -n "$LATEST_BACKUP" ]] || fail "Бэкапы не найдены в $BACKUP_ROOT/$PROJECT_NAME"
echo "Самый свежий бэкап: $LATEST_BACKUP"
read -rp 'Использовать этот бэкап? (Y/n): ' confirm || exit 0
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    find "$BACKUP_ROOT/$PROJECT_NAME" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r
    read -rp 'Введите имя папки бэкапа: ' BACKUP_DATE || exit 0
else BACKUP_DATE=$LATEST_BACKUP
fi
[[ -n "$BACKUP_DATE" && "$BACKUP_DATE" != */* && "$BACKUP_DATE" != . && "$BACKUP_DATE" != .. ]] || fail 'Некорректное имя бэкапа'
BACKUP_DIR="$BACKUP_ROOT/$PROJECT_NAME/$BACKUP_DATE"
[[ -d "$BACKUP_DIR" ]] || fail 'Папка бэкапа не найдена'
BACKUP_ABS=$(cd "$BACKUP_DIR" && pwd -P) || fail 'Не удалось определить путь бэкапа'
SAVED_COMPOSE=''
[[ ! -f "$BACKUP_DIR/.compose_filename" ]] || SAVED_COMPOSE=$(cat "$BACKUP_DIR/.compose_filename")
DEFAULT_COMPOSE=$SAVED_COMPOSE
if [[ -z "$DEFAULT_COMPOSE" ]]; then
    for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
        if [[ -f "$BACKUP_DIR/$f" || -f "$f" ]]; then DEFAULT_COMPOSE=$f; break; fi
    done
fi
DEFAULT_COMPOSE=${DEFAULT_COMPOSE:-compose.yaml}
read -rp "Имя compose-файла [$DEFAULT_COMPOSE]: " COMPOSE || exit 0
COMPOSE=${COMPOSE:-$DEFAULT_COMPOSE}
[[ -n "$COMPOSE" && "$COMPOSE" != */* && "$COMPOSE" != . && "$COMPOSE" != .. ]] || fail 'Некорректное имя Compose'
DC=(docker compose -f "$COMPOSE")

# A missing or invalid legacy Compose must not block image/config restoration.
MAP_ERROR='' VOLUME_MAP=''
if [[ -f "$BACKUP_DIR/.volume-map" ]]; then
    VOLUME_MAP=$(cat "$BACKUP_DIR/.volume-map") || MAP_ERROR='не удалось прочитать таблицу имён'
    LEGACY_VOLUMES=0
else
    LEGACY_VOLUMES=1
    CONFIG_DC=(docker compose --project-directory "$PWD" -f "$BACKUP_DIR/$COMPOSE")
    [[ ! -f "$BACKUP_DIR/.env" ]] || CONFIG_DC+=(--env-file "$BACKUP_DIR/.env")
    if [[ ! -f "$BACKUP_DIR/$COMPOSE" ]]; then
        MAP_ERROR='нет сохранённого Compose для определения имён'
    elif ! RESOLVED_CONFIG=$("${CONFIG_DC[@]}" config); then
        MAP_ERROR='не удалось прочитать сохранённый Compose'
    elif ! VOLUME_MAP=$(printf '%s\n' "$RESOLVED_CONFIG" | awk '
        function unquote(s) { gsub(/^[\042\047]|[\042\047]$/, "", s); return s }
        function check() { if (key != "" && !named) exit 1 }
        /^volumes:$/ { volumes = 1; next }
        /^[^ ]/ { if (volumes) check(); volumes = 0; key = "" }
        volumes && /^  [^ ]/ {
            check(); key = $0; sub(/^  /, "", key); sub(/:$/, "", key)
            key = unquote(key); named = 0
        }
        volumes && /^    name: / {
            name = $0; sub(/^    name: /, "", name)
            printf "%s\t%s\n", key, unquote(name); named = 1
        }
        END { if (volumes) check() }
    '); then MAP_ERROR='Compose не вернул точные имена томов'
    fi
fi
declare -A VOLUME_NAMES=() BIND_PATHS=()
BIND_MAP_ERROR=''
STOP_ERROR=''
[[ -f "$COMPOSE" || -f "$BACKUP_DIR/$COMPOSE" ]] || STOP_ERROR='нет Compose для безопасной остановки контейнеров'
while IFS=$'\t' read -r logical physical extra; do
    [[ -n "$logical" || -n "$physical" ]] || continue
    if [[ ! "$logical" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ || ! "$physical" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ || -n "$extra" ]]; then
        MAP_ERROR='некорректная таблица имён томов'; break
    fi
    if [[ "$LEGACY_VOLUMES" -eq 1 ]]; then VOLUME_NAMES[$logical]=$physical
    else VOLUME_NAMES[$physical]=$physical
    fi
done <<< "$VOLUME_MAP"
if [[ -f "$BACKUP_DIR/.bind-map" ]]; then
    while IFS=$'\t' read -r archive destination extra; do
        [[ -n "$archive" ]] || continue
        if [[ "$archive" != bind_*.tar.gz || "$archive" == */* || "$destination" != /* || -n "$extra" ]]; then
            BIND_MAP_ERROR='некорректная таблица bind mounts'; break
        fi
        BIND_PATHS[$archive]=$destination
    done < "$BACKUP_DIR/.bind-map"
fi

VOLUME_FILES=() BIND_FILES=() IMAGE_FILES=()
for file in "$BACKUP_DIR"/volume_*_backup.tar.gz; do
    [[ -f "$file" ]] || continue
    VOLUME_FILES+=("$file")
    vol=${file##*/}; vol=${vol#volume_}; vol=${vol%_backup.tar.gz}
    reason=$MAP_ERROR
    if [[ -z "$reason" ]]; then
        if [[ ! "$vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ || -z "${VOLUME_NAMES[$vol]:-}" ]]; then reason='нет точного имени назначения'
        elif ! archive_safe "$file"; then reason='повреждённый или небезопасный архив'
        fi
    fi
    [[ -n "$reason" ]] || reason=$STOP_ERROR
    add_item "volume:$file" "Том: $vol → ${VOLUME_NAMES[$vol]:-?}" "$reason"
done
if [[ -z "$MAP_ERROR" ]]; then
    for vol in "${!VOLUME_NAMES[@]}"; do
        [[ -f "$BACKUP_DIR/volume_${vol}_backup.tar.gz" ]] || add_item "missing:$vol" "Том: ${VOLUME_NAMES[$vol]}" 'нет архива в выбранном бэкапе'
    done
fi
[[ ${#ITEM_KEYS[@]} -gt 0 ]] || add_item volumes 'Тома' "${MAP_ERROR:-нет архивов томов}"
for file in "$BACKUP_DIR"/bind_*.tar.gz; do
    [[ -f "$file" ]] || continue
    BIND_FILES+=("$file")
    archive=${file##*/}; folder=${archive#bind_}; folder=${folder%.tar.gz}
    destination=${BIND_PATHS[$archive]:-$PWD/$folder}
    BIND_PATHS[$archive]=$destination
    reason=$BIND_MAP_ERROR
    if [[ -z "$reason" ]]; then
        if [[ -z "$folder" || "$folder" == . || "$folder" == .. ]] || ! bind_destination_safe "$destination"; then reason='небезопасный путь или путь содержит текущий бэкап'
        elif ! archive_safe "$file"; then reason='повреждённый или небезопасный архив'
        fi
    fi
    [[ -n "$reason" ]] || reason=$STOP_ERROR
    add_item "bind:$file" "Bind: $archive → $destination" "$reason"
done
[[ ${#BIND_FILES[@]} -gt 0 ]] || add_item binds 'Bind mounts' 'нет архивов bind mounts'
for file in "$BACKUP_DIR"/image_*.tar; do
    [[ -f "$file" ]] || continue
    IMAGE_FILES+=("$file")
    reason=''
    tar -tf "$file" >/dev/null 2>&1 || reason='повреждённый архив образа'
    add_item "image:$file" "Образ: ${file##*/}" "$reason"
done
[[ ${#IMAGE_FILES[@]} -gt 0 ]] || add_item images 'Образы' 'нет архивов образов'
reason=''; [[ -f "$BACKUP_DIR/$COMPOSE" ]] || reason='файл отсутствует в бэкапе'
add_item compose "Конфиг: $COMPOSE" "$reason"
reason=''; [[ -f "$BACKUP_DIR/.env" ]] || reason='файл отсутствует в бэкапе'
add_item env 'Конфиг: .env' "$reason"
for file in "$BACKUP_DIR"/container_*.inspect.json; do
    [[ -f "$file" ]] || continue
    name=${file##*/}; name=${name#container_}; name=${name%.inspect.json}
    add_item "container:$file" "Описание контейнера: $name" 'справочный inspect; контейнер пересоздаёт его управляющий сервис или оператор'
done

if ! select_items 'Выберите, что восстановить'; then echo 'Восстановление отменено.'; exit 0; fi
echo 'Будет восстановлено:'
for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
    [[ "${ITEM_SELECTED[i]}" -eq 0 ]] || printf '  • %s\n' "${ITEM_LABELS[i]}"
done
DATA_SELECTED=0
CONSUMER_IDS=()
for file in "${VOLUME_FILES[@]}"; do selected "volume:$file" && DATA_SELECTED=1; done
for file in "${BIND_FILES[@]}"; do selected "bind:$file" && DATA_SELECTED=1; done
if [[ "$DATA_SELECTED" -eq 1 ]]; then
    echo 'Выбранные данные будут заменены. Compose и контейнеры-потребители будут остановлены и останутся остановленными.'
    echo 'До подтверждения остановите внешние управляющие сервисы и процессы хоста, которые могут записывать эти данные.'
    echo 'Не запускайте потребителей до окончания восстановления; проверка mounts не блокирует их запуск.'
    CONSUMERS=$(find_running_consumers) || fail 'Не удалось определить потребителей выбранных данных'
    if [[ -n "$CONSUMERS" ]]; then
        echo 'Дополнительная остановка контейнеров, использующих выбранные данные:'
        while IFS=$'\t' read -r id name; do
            [[ -n "$id" ]] || continue
            CONSUMER_IDS+=("$id")
            printf '  • %s (%s)\n' "$name" "$id"
        done <<< "$CONSUMERS"
    fi
    # Validate selected archives again before stopping containers.
    for file in "${VOLUME_FILES[@]}"; do
        selected "volume:$file" || continue
        archive_safe "$file" || fail "Архив изменился или повреждён: $file"
    done
    for file in "${BIND_FILES[@]}"; do
        selected "bind:$file" || continue
        archive_safe "$file" || fail "Архив изменился или повреждён: $file"
        bind_destination_safe "${BIND_PATHS[${file##*/}]}" || fail 'Путь bind mount стал небезопасным'
    done
else
    echo 'Будут восстановлены только выбранные образы/конфиги. Контейнеры не будут остановлены.'
fi
read -rp 'Начать восстановление? Введите RESTORE: ' stop_confirm || exit 0
[[ "$stop_confirm" == RESTORE ]] || { echo 'Восстановление отменено.'; exit 0; }
if [[ "$DATA_SELECTED" -eq 1 ]]; then
    STOP_DC=("${DC[@]}")
    if [[ ! -f "$COMPOSE" ]]; then
        [[ -f "$BACKUP_DIR/$COMPOSE" ]] || fail 'Нет Compose для безопасной остановки контейнеров'
        STOP_DC=(docker compose --project-directory "$PWD" -f "$BACKUP_DIR/$COMPOSE")
        [[ ! -f "$BACKUP_DIR/.env" ]] || STOP_DC+=(--env-file "$BACKUP_DIR/.env")
    fi
    "${STOP_DC[@]}" stop || fail 'Не удалось остановить контейнеры; данные не изменены'
    if [[ ${#CONSUMER_IDS[@]} -gt 0 ]]; then
        docker stop "${CONSUMER_IDS[@]}" || fail 'Не удалось остановить потребителей; данные не изменены'
    fi
    require_stopped_destinations
fi
for file in "${BIND_FILES[@]}"; do
    selected "bind:$file" || continue
    destination=${BIND_PATHS[${file##*/}]}
    bind_destination_safe "$destination" || fail "Путь стал небезопасным: $destination"
    restore_tmp=$(mktemp -d) || fail 'Не удалось создать временную папку'
    if ! tar -xzf "$file" -C "$restore_tmp"; then
        cleanup_restore_tmp; fail "Ошибка распаковки: $file"
    fi
    folder=${file##*/}; folder=${folder#bind_}; folder=${folder%.tar.gz}
    if [[ ! -e "$restore_tmp/$folder" || -L "$restore_tmp/$folder" ]]; then
        cleanup_restore_tmp; fail "Архив не содержит ожидаемый путь: $folder"
    fi
    require_stopped_destinations
    if [[ -d "$restore_tmp/$folder" ]]; then
        mkdir -p "$destination" && find "$destination" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a "$restore_tmp/$folder/." "$destination/" || fail "Ошибка восстановления: $destination"
    else
        [[ ! -d "$destination" ]] || fail "Ожидался файл, но найдена папка: $destination"
        mkdir -p "$(dirname "$destination")" && cp -a "$restore_tmp/$folder" "$destination" || fail "Ошибка восстановления: $destination"
    fi
    cleanup_restore_tmp
    echo "✓ Bind: $destination"
done
for file in "${VOLUME_FILES[@]}"; do
    selected "volume:$file" || continue
    vol=${file##*/}; vol=${vol#volume_}; vol=${vol%_backup.tar.gz}
    REAL_VOL=${VOLUME_NAMES[$vol]}
    if ! docker volume inspect "$REAL_VOL" >/dev/null 2>&1; then
        docker volume create "$REAL_VOL" >/dev/null || fail "Не удалось создать том: $REAL_VOL"
    fi
    require_stopped_destinations
    docker run --rm -v "${REAL_VOL}:/data" -v "$PWD/$BACKUP_DIR:/backup:ro" alpine sh -c \
        'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar xzf "/backup/$1" -C /data' sh "${file##*/}" || fail "Ошибка восстановления: $REAL_VOL"
    echo "✓ Том: $REAL_VOL"
done
for file in "${IMAGE_FILES[@]}"; do
    selected "image:$file" || continue
    docker load -i "$file" || fail "Ошибка загрузки: $file"
done
if selected compose; then cp -f "$BACKUP_DIR/$COMPOSE" "$COMPOSE" || fail 'Ошибка копирования Compose'; fi
if selected env; then cp -f "$BACKUP_DIR/.env" .env || fail 'Ошибка копирования .env'; fi
echo '✅ Выбранные элементы восстановлены.'
