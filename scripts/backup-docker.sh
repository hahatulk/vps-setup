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

PROJECT_NAME=$(basename "$PWD")
DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_DIR="./backups/$PROJECT_NAME/$DATE"
DEFAULT_COMPOSE=''
for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    if [[ -f "$f" ]]; then DEFAULT_COMPOSE=$f; break; fi
done
echo "=== Docker Backup: $PROJECT_NAME ==="
read -rp "Имя compose-файла [$DEFAULT_COMPOSE]: " COMPOSE || exit 0
COMPOSE=${COMPOSE:-$DEFAULT_COMPOSE}
[[ -n "$COMPOSE" && -f "$COMPOSE" ]] || fail "Файл '$COMPOSE' не найден"
DC=(docker compose -f "$COMPOSE")
RESOLVED_CONFIG=$("${DC[@]}" config) || fail 'Не удалось прочитать конфигурацию Compose'

# Read physical names from normalized Compose output, never from suffix matches.
VOLUME_MAP=$(printf '%s\n' "$RESOLVED_CONFIG" | awk '
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
') || fail 'Compose не вернул точные имена томов'

VOLUMES=() BINDS=() IMAGES=()
declare -A SEEN_VOLUMES=() SEEN_BINDS=() BIND_NAMES=() IMAGE_NAMES=()
while IFS=$'\t' read -r logical physical; do
    [[ -n "$logical" ]] || continue
    [[ "$logical" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$physical" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail 'Некорректное имя тома'
    [[ -z "${SEEN_VOLUMES[$physical]:-}" ]] || continue
    SEEN_VOLUMES[$physical]=1
    VOLUMES+=("$physical")
    reason=''
    docker volume inspect "$physical" >/dev/null 2>&1 || reason='исходный том не найден или Docker недоступен'
    add_item "volume:$physical" "Том: $physical" "$reason"
done <<< "$VOLUME_MAP"
[[ ${#VOLUMES[@]} -gt 0 ]] || add_item volumes 'Тома' 'в Compose нет именованных томов'

# Normalized Compose includes both short and long bind mount syntax.
BIND_SOURCES=$(printf '%s\n' "$RESOLVED_CONFIG" | awk '
    /- type: / { bind = ($0 ~ /- type: bind$/) }
    bind && /^[ ]+source: / {
        sub(/^[ ]+source: /, ""); gsub(/^[\042\047]|[\042\047]$/, ""); print; bind = 0
    }
')
while IFS= read -r host_path; do
    [[ -n "$host_path" ]] || continue
    [[ -z "${SEEN_BINDS[$host_path]:-}" ]] || continue
    SEEN_BINDS[$host_path]=1
    BINDS+=("$host_path")
    name=$(basename "$host_path")
    reason=''
    if [[ ! -e "$host_path" ]]; then reason='исходный путь не найден'
    elif [[ "$host_path" == / || "$name" == . || "$name" == .. ]]; then reason='небезопасный путь'
    elif [[ -n "${BIND_NAMES[$name]:-}" ]]; then reason='совпадает имя архива другого bind mount'
    else BIND_NAMES[$name]=$host_path
    fi
    add_item "bind:$host_path" "Bind: $host_path" "$reason"
done <<< "$BIND_SOURCES"
[[ ${#BINDS[@]} -gt 0 ]] || add_item binds 'Bind mounts' 'в Compose нет bind mounts'

IMAGE_LIST=$("${DC[@]}" config --images) || fail 'Не удалось получить список образов'
while IFS= read -r image; do
    [[ -n "$image" && "$image" != null ]] || continue
    safe_name=$(printf '%s' "$image" | tr '/:' '_')
    IMAGES+=("$image")
    reason=''
    if [[ -n "${IMAGE_NAMES[$safe_name]:-}" ]]; then
        reason='совпадает имя архива другого образа'
    else
        IMAGE_NAMES[$safe_name]=$image
        docker image inspect "$image" >/dev/null 2>&1 || reason='локальный образ не найден или Docker недоступен'
    fi
    add_item "image:$image" "Образ: $image" "$reason"
done < <(printf '%s\n' "$IMAGE_LIST" | sort -u)
[[ ${#IMAGES[@]} -gt 0 ]] || add_item images 'Образы' 'в Compose нет образов'
add_item compose "Конфиг: $COMPOSE"
reason=''; [[ -f .env ]] || reason='файл отсутствует'
add_item env 'Конфиг: .env' "$reason"

if ! select_items 'Выберите, что сохранить'; then echo 'Бэкап отменён.'; exit 0; fi
echo 'Будет сохранено:'
for ((i=0; i<${#ITEM_KEYS[@]}; i++)); do
    [[ "${ITEM_SELECTED[i]}" -eq 0 ]] || printf '  • %s\n' "${ITEM_LABELS[i]}"
done

# Recheck selected sources before creating any backup files.
for physical in "${VOLUMES[@]}"; do
    selected "volume:$physical" || continue
    docker volume inspect "$physical" >/dev/null || fail "Исходный том исчез: $physical"
done
[[ ! -e "$BACKUP_DIR" ]] || fail "Папка бэкапа уже существует: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || fail 'Не удалось создать папку бэкапа'
# Metadata is required even when the user does not select the Compose file.
printf '%s\n' "$VOLUME_MAP" > "$BACKUP_DIR/.volume-map"
printf '%s\n' "$(basename "$COMPOSE")" > "$BACKUP_DIR/.compose_filename"
: > "$BACKUP_DIR/.bind-map"
echo "Бэкап в: $BACKUP_DIR"
for host_path in "${BINDS[@]}"; do
    selected "bind:$host_path" || continue
    name=$(basename "$host_path")
    echo "→ Bind: $host_path"
    if ! tar -czf "$BACKUP_DIR/bind_${name}.tar.gz" --exclude='./backups' --exclude="$name/backups" -C "$(dirname "$host_path")" "$name"; then
        rm -f "$BACKUP_DIR/bind_${name}.tar.gz"
        fail "Ошибка бэкапа: $host_path"
    fi
    printf '%s\t%s\n' "bind_${name}.tar.gz" "$host_path" >> "$BACKUP_DIR/.bind-map"
done
for physical in "${VOLUMES[@]}"; do
    selected "volume:$physical" || continue
    echo "→ Том: $physical"
    if ! docker run --rm --mount "type=volume,src=${physical},dst=/volume_data,readonly" \
        -v "$PWD/$BACKUP_DIR:/backup" alpine tar czf "/backup/volume_${physical}_backup.tar.gz" -C /volume_data .; then
        rm -f "$BACKUP_DIR/volume_${physical}_backup.tar.gz"
        fail "Ошибка бэкапа: $physical"
    fi
done
for image in "${IMAGES[@]}"; do
    selected "image:$image" || continue
    safe_name=$(printf '%s' "$image" | tr '/:' '_')
    echo "→ Образ: $image"
    docker save "$image" -o "$BACKUP_DIR/image_${safe_name}.tar" || fail "Ошибка сохранения: $image"
done
if selected compose; then cp "$COMPOSE" "$BACKUP_DIR/" || fail 'Ошибка копирования Compose'; fi
if selected env; then cp .env "$BACKUP_DIR/" || fail 'Ошибка копирования .env'; fi
echo "✅ Бэкап завершён: $BACKUP_DIR"
du -sh "$BACKUP_DIR"
