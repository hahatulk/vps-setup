#!/usr/bin/env bash
set -euo pipefail

SCRIPTS=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'result=$?; if [[ "$result" -eq 0 ]]; then rm -rf "$TEST_ROOT"; else echo "FAIL: test files kept at $TEST_ROOT" >&2; fi' EXIT
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/project" "$TEST_ROOT/payload"
printf 'test data\n' > "$TEST_ROOT/payload/data"
export TEST_ROOT
export PATH="$TEST_ROOT/bin:$PATH"

# Do not contact a Docker daemon. Record exact volume operations instead.
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_ROOT/docker.log"
case "$1 $2" in
    'compose -f'|'compose --project-directory')
        case "${*: -1}" in
            config) cat "$TEST_ROOT/config.yaml" ;;
            --images) [[ ! -f "$TEST_ROOT/images" ]] || cat "$TEST_ROOT/images" ;;
            --quiet) [[ ! -f "$TEST_ROOT/compose-ids" ]] || cat "$TEST_ROOT/compose-ids" ;;
            stop) [[ "${FAIL_STOP:-0}" == 0 ]] ;;
            *) exit 1 ;;
        esac ;;
    'ps --all') [[ ! -f "$TEST_ROOT/containers" ]] || cat "$TEST_ROOT/containers" ;;
    'ps --quiet')
        if [[ -n "${LATE_RUNNING_AFTER:-}" ]]; then
            count=0
            [[ ! -f "$TEST_ROOT/ps-count" ]] || count=$(cat "$TEST_ROOT/ps-count")
            printf '%s\n' "$((count+1))" > "$TEST_ROOT/ps-count"
        fi
        [[ ! -f "$TEST_ROOT/running-ids" ]] || cat "$TEST_ROOT/running-ids" ;;
    'container inspect')
        id=${*: -1}
        [[ "${FAIL_INSPECT:-}" != "$id" ]] || exit 1
        if [[ "$3" != --format ]]; then
            printf '[{"Id":"%s","Config":{"Env":["TEST_SECRET=local-only"]}}]\n' "$id"
        elif [[ "$4" == '{{if .State.Running}}'* ]]; then
            late=0
            if [[ "${LATE_ID:-}" == "$id" && -n "${LATE_RUNNING_AFTER:-}" && -f "$TEST_ROOT/ps-count" ]]; then
                [[ $(cat "$TEST_ROOT/ps-count") -lt "$LATE_RUNNING_AFTER" ]] || late=1
            fi
            if [[ ! -f "$TEST_ROOT/stopped.$id" || "${KEEP_RUNNING:-0}" == 1 || "$late" == 1 ]]; then
                [[ ! -f "$TEST_ROOT/running.$id" ]] || cat "$TEST_ROOT/running.$id"
            fi
        else
            cat "$TEST_ROOT/resources.$id"
        fi ;;
    'stop '*)
        [[ "${FAIL_CONSUMER_STOP:-0}" == 0 ]] || exit 1
        shift
        for id in "$@"; do touch "$TEST_ROOT/stopped.$id"; done ;;
    'volume inspect') [[ "${MISSING_VOLUME:-}" != "$3" ]] ;;
    'volume create') : ;;
    'image inspect')
        [[ "${MISSING_IMAGE:-}" != "${*: -1}" ]] || exit 1
        if [[ "$3" == --format ]]; then
            if [[ "${*: -1}" == sha256:* ]]; then printf '%s\n' "${*: -1}"
            else cat "$TEST_ROOT/image-id"
            fi
        fi ;;
    'save '*) tar -cf "$4" -C "$TEST_ROOT/payload" . ;;
    'load -i') : ;;
    'run --rm')
        backup_dir=''
        for arg in "$@"; do
            [[ "$arg" != *:/backup ]] || backup_dir=${arg%:/backup}
        done
        for arg in "$@"; do
            if [[ "$arg" == /backup/volume_* ]]; then
                tar -czf "$backup_dir/${arg##*/}" -C "$TEST_ROOT/payload" .
            fi
        done ;;
    *) echo "Unexpected Docker command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/docker"
cat > "$TEST_ROOT/config.yaml" <<'CONFIG'
name: original_project
services:
  app:
    image: example
volumes:
  database:
    name: original_project_database
  explicit:
    name: nextcloud_aio_mastercontainer
  external:
    name: shared_storage
    external: true
  numeric:
    name: "12345"
CONFIG
cd "$TEST_ROOT/project"
printf 'services: {}\n' > compose.yaml

printf '\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/backup.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -n "$BACKUP" ]]
for name in original_project_database nextcloud_aio_mastercontainer shared_storage 12345; do
    [[ -f "$BACKUP/volume_${name}_backup.tar.gz" ]]
done
! grep -q 'volume ls' "$TEST_ROOT/docker.log"

# Restore uses the saved physical names even if Compose now resolves other names.
printf 'services: {}\nvolumes: {}\n' > "$TEST_ROOT/config.yaml"
: > "$TEST_ROOT/docker.log"
printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/restore.log" 2>&1
for name in original_project_database nextcloud_aio_mastercontainer shared_storage 12345; do
    grep -Fq -- "-v $name:/data" "$TEST_ROOT/docker.log"
done
! grep -q 'project_nextcloud\|volume ls' "$TEST_ROOT/docker.log"

# Legacy archives use logical keys, resolved against the saved Compose file.
rm "$BACKUP/.volume-map" "$BACKUP"/volume_*_backup.tar.gz
cat > "$TEST_ROOT/config.yaml" <<'CONFIG'
name: project
services: {}
volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
  database:
    name: project_database
CONFIG
for name in nextcloud_aio_mastercontainer database; do
    tar -czf "$BACKUP/volume_${name}_backup.tar.gz" -C "$TEST_ROOT/payload" .
done
: > "$TEST_ROOT/docker.log"
export MISSING_VOLUME=nextcloud_aio_mastercontainer
printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/legacy.log" 2>&1
unset MISSING_VOLUME
grep -Fxq 'volume create nextcloud_aio_mastercontainer' "$TEST_ROOT/docker.log"
grep -Fq -- '-v nextcloud_aio_mastercontainer:/data' "$TEST_ROOT/docker.log"
grep -Fq -- '-v project_database:/data' "$TEST_ROOT/docker.log"
! grep -q 'project_nextcloud\|volume ls' "$TEST_ROOT/docker.log"

# Unknown archives are disabled; cancellation has no side effects.
tar -czf "$BACKUP/volume_unknown_backup.tar.gz" -C "$TEST_ROOT/payload" .
: > "$TEST_ROOT/docker.log"
printf '\n\nq\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/unknown.log" 2>&1
grep -q '\[!\].*unknown.*нет точного имени' "$TEST_ROOT/unknown.log"
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"

# A missing source is shown as unavailable, without creating an empty volume.
: > "$TEST_ROOT/docker.log"
export MISSING_VOLUME=nextcloud_aio_mastercontainer
printf '\nq\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/missing.log" 2>&1
unset MISSING_VOLUME
grep -q '\[!\].*nextcloud_aio_mastercontainer.*исходный том не найден' "$TEST_ROOT/missing.log"
! grep -q 'run --rm\|volume create' "$TEST_ROOT/docker.log"
# Invalid menu input, empty selection, EOF and cancellation must not write data.
: > "$TEST_ROOT/docker.log"
printf '\n\nn\ns\n000000\n999999\ninvalid\nq\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/empty.log" 2>&1
grep -q 'Выберите хотя бы один пункт' "$TEST_ROOT/empty.log"
! grep -q ' stop$\|run --rm\|volume create\|load -i' "$TEST_ROOT/docker.log"
printf '\n\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/eof.log" 2>&1
! grep -q ' stop$\|run --rm\|volume create\|load -i' "$TEST_ROOT/docker.log"

# Select just one source. Unselected images, binds and configs must not be saved.
rm -rf backups
mkdir -p "$TEST_ROOT/bind-source"
printf 'bind data\n' > "$TEST_ROOT/bind-source/file"
printf 'example\n' > "$TEST_ROOT/images"
cat > "$TEST_ROOT/config.yaml" <<CONFIG
name: project
services:
  app:
    image: example
    volumes:
      - type: bind
        source: $TEST_ROOT/bind-source
        target: /bind
volumes:
  first:
    name: exact_first
  second:
    name: exact_second
CONFIG
: > "$TEST_ROOT/docker.log"
printf '\nn\n1\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/select-backup.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -f "$BACKUP/volume_exact_first_backup.tar.gz" ]]
[[ ! -f "$BACKUP/volume_exact_second_backup.tar.gz" && ! -f "$BACKUP/compose.yaml" ]]
[[ ! -f "$BACKUP/bind_bind-source.tar.gz" && ! -f "$BACKUP/image_example.tar" ]]
! grep -q '^save ' "$TEST_ROOT/docker.log"

# A data-only backup remains restorable with its name metadata.
: > "$TEST_ROOT/docker.log"
printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/select-restore.log" 2>&1
grep -Fq -- '-v exact_first:/data' "$TEST_ROOT/docker.log"
! grep -q 'exact_second:/data' "$TEST_ROOT/docker.log"
grep -q '\[!\].*exact_second.*нет архива' "$TEST_ROOT/select-restore.log"

# Do not write data after a failed stop, or without destructive confirmation.
: > "$TEST_ROOT/docker.log"
export FAIL_STOP=1
if printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/stop.log" 2>&1; then
    echo 'FAIL: failed stop accepted' >&2; exit 1
fi
unset FAIL_STOP
! grep -q 'run --rm\|volume create' "$TEST_ROOT/docker.log"
: > "$TEST_ROOT/docker.log"
printf '\n\ns\nNO\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/confirmation.log" 2>&1
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"

# Select only bind data, image and Compose; do not save volumes.
rm -rf backups
: > "$TEST_ROOT/docker.log"
printf '\nn\n3 4 5\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/bind-backup.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -f "$BACKUP/bind_bind-source.tar.gz" && -f "$BACKUP/image_example.tar" && -f "$BACKUP/compose.yaml" ]]
[[ ! -f "$BACKUP/volume_exact_first_backup.tar.gz" && ! -f "$BACKUP/volume_exact_second_backup.tar.gz" ]]
! grep -q 'run --rm' "$TEST_ROOT/docker.log"

# Restore only image and config: keep bind data and running containers unchanged.
# Menu order: missing volumes 1/2, bind 3, image 4, Compose 5, .env 6.
printf 'keep this\n' > "$TEST_ROOT/bind-source/file"
: > "$TEST_ROOT/docker.log"
printf '\n\nn\n4 5\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/image-only.log" 2>&1
grep -q '^load -i ' "$TEST_ROOT/docker.log"
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"
grep -q 'keep this' "$TEST_ROOT/bind-source/file"

# Restore only the selected bind to its recorded source path.
: > "$TEST_ROOT/docker.log"
printf '\n\nn\n3\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/bind-restore.log" 2>&1
grep -q 'bind data' "$TEST_ROOT/bind-source/file"
! grep -q 'run --rm\|load -i' "$TEST_ROOT/docker.log"

# A damaged archive is disabled while other entries remain available.
printf 'not an archive' > "$BACKUP/bind_bind-source.tar.gz"
: > "$TEST_ROOT/docker.log"
printf '\n\nq\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/corrupt.log" 2>&1
grep -q '\[!\].*bind_bind-source.*повреждённый' "$TEST_ROOT/corrupt.log"
! grep -q ' stop$\|run --rm\|load -i' "$TEST_ROOT/docker.log"

# Never restore a bind over the directory that contains the active backup.
printf '%s\t%s\n' bind_bind-source.tar.gz "$PWD" > "$BACKUP/.bind-map"
printf '\n\nq\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/unsafe-bind.log" 2>&1
grep -q '\[!\].*bind_bind-source.*путь содержит текущий бэкап' "$TEST_ROOT/unsafe-bind.log"
# Select-all still excludes missing/corrupt/unsafe entries.
: > "$TEST_ROOT/docker.log"
printf '\n\nn\na\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/all.log" 2>&1
grep -q '^load -i ' "$TEST_ROOT/docker.log"
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"

# Missing legacy Compose disables volumes, not independent image restoration.
rm "$BACKUP/.volume-map" "$BACKUP/compose.yaml"
: > "$TEST_ROOT/docker.log"
printf '\n\nn\n3\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/no-compose.log" 2>&1
grep -q 'нет сохранённого Compose' "$TEST_ROOT/no-compose.log"
grep -q '^load -i ' "$TEST_ROOT/docker.log"
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"

# File bind mounts use the same recorded path and checkbox selection.
rm "$BACKUP/bind_bind-source.tar.gz"
printf 'original file\n' > "$TEST_ROOT/settings.conf"
tar -czf "$BACKUP/bind_settings.conf.tar.gz" -C "$TEST_ROOT" settings.conf
printf '%s\t%s\n' bind_settings.conf.tar.gz "$TEST_ROOT/settings.conf" > "$BACKUP/.bind-map"
printf 'changed file\n' > "$TEST_ROOT/settings.conf"
: > "$TEST_ROOT/docker.log"
printf '\n\nn\n2\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/file-bind.log" 2>&1
grep -q 'original file' "$TEST_ROOT/settings.conf"
! grep -q 'run --rm\|load -i' "$TEST_ROOT/docker.log"
# Extra containers have no generic parent relation. Require explicit selection.
rm -rf backups
rm -f "$TEST_ROOT/running-ids"
NC_ID=1111111111111111111111111111111111111111111111111111111111111111
DB_ID=2222222222222222222222222222222222222222222222222222222222222222
OTHER_ID=3333333333333333333333333333333333333333333333333333333333333333
ROOT_ID=4444444444444444444444444444444444444444444444444444444444444444
NC_IMAGE="sha256:$NC_ID"
DB_IMAGE="sha256:$DB_ID"
printf '%s\n' "$ROOT_ID" > "$TEST_ROOT/compose-ids"
printf '%s\t%s\n' "$NC_ID" nextcloud-aio-nextcloud "$DB_ID" nextcloud-aio-database "$OTHER_ID" unrelated "$ROOT_ID" aio-master > "$TEST_ROOT/containers"
printf '%s\n' "$NC_IMAGE" > "$TEST_ROOT/image-id"
printf 'aio-master:latest\n' > "$TEST_ROOT/images"
mkdir -p "$TEST_ROOT/aio-data"
printf 'user files\n' > "$TEST_ROOT/aio-data/file"
mkfifo "$TEST_ROOT/docker.sock"
cat > "$TEST_ROOT/config.yaml" <<'CONFIG'
name: project
services: {}
volumes:
  master:
    name: nextcloud_aio_mastercontainer
CONFIG
printf '%s\t%s\t%s\n' image "$NC_IMAGE" ghcr.io/example/nextcloud:latest > "$TEST_ROOT/resources.$NC_ID"
printf '%s\t%s\n' volume nextcloud_aio_nextcloud volume shared_data bind "$TEST_ROOT/aio-data" bind "$TEST_ROOT/docker.sock" >> "$TEST_ROOT/resources.$NC_ID"
printf '%s\t%s\t%s\n' image "$DB_IMAGE" postgres:16 > "$TEST_ROOT/resources.$DB_ID"
printf '%s\t%s\n' volume nextcloud_aio_database volume shared_data bind "$TEST_ROOT/aio-data" >> "$TEST_ROOT/resources.$DB_ID"
: > "$TEST_ROOT/docker.log"
printf '\n1 2\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/children.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
for name in nextcloud_aio_mastercontainer nextcloud_aio_nextcloud nextcloud_aio_database shared_data; do
    [[ -f "$BACKUP/volume_${name}_backup.tar.gz" ]]
done
[[ -f "$BACKUP/bind_aio-data.tar.gz" && ! -f "$BACKUP/bind_docker.sock.tar.gz" ]]
[[ -f "$BACKUP/image_ghcr.io_example_nextcloud_latest.tar" && -f "$BACKUP/image_sha256_${DB_ID}.tar" ]]
[[ ! -f "$BACKUP/image_postgres_16.tar" ]]
[[ -f "$BACKUP/container_nextcloud-aio-nextcloud.inspect.json" && -f "$BACKUP/container_nextcloud-aio-database.inspect.json" ]]
[[ ! -f "$BACKUP/container_unrelated.inspect.json" && ! -f "$BACKUP/container_aio-master.inspect.json" ]]
[[ $(grep -c 'type=volume,src=shared_data,' "$TEST_ROOT/docker.log") -eq 1 ]]
[[ $(grep -c '^save ghcr.io/example/nextcloud:latest ' "$TEST_ROOT/docker.log") -eq 1 ]]
! grep -q 'TEST_SECRET' "$TEST_ROOT/children.log"
! grep -q 'Контейнер: aio-master' "$TEST_ROOT/children.log"
grep -q '\[!\].*docker.sock.*не обычный файл' "$TEST_ROOT/children.log"
mv backups children-backup

# No extra container is selected by default; an empty scope selection is valid.
: > "$TEST_ROOT/docker.log"
printf '\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/no-children.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -f "$BACKUP/volume_nextcloud_aio_mastercontainer_backup.tar.gz" ]]
[[ ! -f "$BACKUP/volume_nextcloud_aio_nextcloud_backup.tar.gz" ]]
! grep -q '^container inspect ' "$TEST_ROOT/docker.log"
rm -rf backups
: > "$TEST_ROOT/docker.log"
printf '\nq\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/scope-cancel.log" 2>&1
[[ ! -e backups ]]
! grep -q '^container inspect\|run --rm\|^save ' "$TEST_ROOT/docker.log"

# Do not archive a live database or data used by an unselected container.
printf '%s\n' "$NC_ID" > "$TEST_ROOT/running-ids"
printf '%s\t%s\t%s\n' volume nextcloud_aio_nextcloud /nextcloud-aio-nextcloud > "$TEST_ROOT/running.$NC_ID"
: > "$TEST_ROOT/docker.log"
if printf '\n1\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/live-child.log" 2>&1; then
    echo 'FAIL: live child data archived' >&2; exit 1
fi
[[ ! -e backups ]]
! grep -q 'run --rm\|^save \|^stop ' "$TEST_ROOT/docker.log"
grep -q 'работающий контейнер /nextcloud-aio-nextcloud' "$TEST_ROOT/live-child.log"
printf '%s\n' "$OTHER_ID" > "$TEST_ROOT/running-ids"
printf '%s\t%s\t%s\n' volume nextcloud_aio_mastercontainer /unselected-consumer > "$TEST_ROOT/running.$OTHER_ID"
if printf '\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/live-shared.log" 2>&1; then
    echo 'FAIL: data shared with unselected container archived' >&2; exit 1
fi
[[ ! -e backups ]]
printf '%s\t%s\t%s\n' bind "$TEST_ROOT" /ancestor-bind-consumer > "$TEST_ROOT/running.$OTHER_ID"
if printf '\n1\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/live-bind.log" 2>&1; then
    echo 'FAIL: overlapping live bind archived' >&2; exit 1
fi
grep -q 'ancestor-bind-consumer' "$TEST_ROOT/live-bind.log"
[[ ! -e backups ]]
printf '%s\t%s\t%s\n' bind / /root-bind-consumer > "$TEST_ROOT/running.$OTHER_ID"
if printf '\n1\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/live-root-bind.log" 2>&1; then
    echo 'FAIL: root bind consumer missed' >&2; exit 1
fi
[[ ! -e backups ]]

# Restore must stop real consumers outside Compose, but not unrelated containers.
mv children-backup backups
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
printf '%s\n' "$NC_ID" "$DB_ID" "$OTHER_ID" > "$TEST_ROOT/running-ids"
printf '%s\t%s\t%s\n' volume nextcloud_aio_database /nextcloud-aio-database > "$TEST_ROOT/running.$DB_ID"
printf '%s\t%s\t%s\n' volume unrelated_volume /unrelated > "$TEST_ROOT/running.$OTHER_ID"
: > "$TEST_ROOT/docker.log"
printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/children-restore.log" 2>&1
grep -Fxq "stop $NC_ID $DB_ID" "$TEST_ROOT/docker.log"
! grep -q "^stop .*${OTHER_ID}" "$TEST_ROOT/docker.log"
for name in nextcloud_aio_nextcloud nextcloud_aio_database shared_data; do
    grep -Fq -- "-v $name:/data" "$TEST_ROOT/docker.log"
done
stop_line=$(grep -n '^stop ' "$TEST_ROOT/docker.log" | head -n 1 | cut -d: -f1)
write_line=$(grep -n '^run --rm' "$TEST_ROOT/docker.log" | head -n 1 | cut -d: -f1)
[[ "$stop_line" -lt "$write_line" ]]
grep -q 'Описание контейнера: nextcloud-aio-nextcloud.*справочный inspect' "$TEST_ROOT/children-restore.log"
! grep -q 'TEST_SECRET' "$TEST_ROOT/children-restore.log"

# Consent and stop failures must prevent all data writes.
rm "$TEST_ROOT/stopped.$NC_ID" "$TEST_ROOT/stopped.$DB_ID"
: > "$TEST_ROOT/docker.log"
printf '\n\ns\nNO\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/children-cancel.log" 2>&1
! grep -q ' stop$\|^stop \|run --rm\|^load ' "$TEST_ROOT/docker.log"
export FAIL_CONSUMER_STOP=1
: > "$TEST_ROOT/docker.log"
if printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/child-stop-fail.log" 2>&1; then
    echo 'FAIL: failed child stop accepted' >&2; exit 1
fi
unset FAIL_CONSUMER_STOP
! grep -q 'run --rm\|^load ' "$TEST_ROOT/docker.log"
export KEEP_RUNNING=1
: > "$TEST_ROOT/docker.log"
if printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/child-restarted.log" 2>&1; then
    echo 'FAIL: restarted consumer accepted' >&2; exit 1
fi
unset KEEP_RUNNING
! grep -q 'run --rm\|^load ' "$TEST_ROOT/docker.log"
export FAIL_INSPECT=$NC_ID
: > "$TEST_ROOT/docker.log"
if printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/child-inspect-fail.log" 2>&1; then
    echo 'FAIL: unverified consumer accepted' >&2; exit 1
fi
unset FAIL_INSPECT
! grep -q ' stop$\|^stop \|run --rm\|^load ' "$TEST_ROOT/docker.log"
# A late consumer after the post-stop check must be caught before the first write.
touch "$TEST_ROOT/stopped.$NC_ID" "$TEST_ROOT/stopped.$DB_ID"
printf 'do not replace\n' > "$TEST_ROOT/aio-data/file"
export LATE_ID=$NC_ID LATE_RUNNING_AFTER=3
rm -f "$TEST_ROOT/ps-count"
: > "$TEST_ROOT/docker.log"
if printf '\n\ns\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/late-consumer.log" 2>&1; then
    echo 'FAIL: late consumer accepted' >&2; exit 1
fi
unset LATE_ID LATE_RUNNING_AFTER
! grep -q 'run --rm\|^load ' "$TEST_ROOT/docker.log"
grep -q 'do not replace' "$TEST_ROOT/aio-data/file"

# Fail closed if source consumers cannot be inspected, before creating output.
mv backups children-backup
rm -f "$TEST_ROOT/stopped.$NC_ID" "$TEST_ROOT/stopped.$DB_ID"
printf '%s\n' "$OTHER_ID" > "$TEST_ROOT/running-ids"
export FAIL_INSPECT=$OTHER_ID
: > "$TEST_ROOT/docker.log"
if printf '\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/source-inspect-fail.log" 2>&1; then
    echo 'FAIL: unverified source accepted' >&2; exit 1
fi
unset FAIL_INSPECT
[[ ! -e backups ]]
! grep -q 'run --rm\|^save ' "$TEST_ROOT/docker.log"

# A broad extra bind can contain the project below several directories.
# Exclude the real backup output, not just an immediate child named backups.
rm -f "$TEST_ROOT/running-ids"
mkdir -p "$TEST_ROOT/ancestor/child/project"
cd "$TEST_ROOT/ancestor/child/project"
printf 'services: {}\n' > compose.yaml
printf 'nested data\n' > "$TEST_ROOT/ancestor/file"
printf '%s\t%s\n' bind "$TEST_ROOT/ancestor" >> "$TEST_ROOT/resources.$NC_ID"
printf '\n1\ns\ns\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/ancestor.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -f "$BACKUP/bind_ancestor.tar.gz" ]]
tar -tzf "$BACKUP/bind_ancestor.tar.gz" > "$TEST_ROOT/ancestor-files"
grep -q '^ancestor/file$' "$TEST_ROOT/ancestor-files"
! grep -q '^ancestor/child/project/backups' "$TEST_ROOT/ancestor-files"
printf 'PASS: exact names, legacy archives, selection/cancellation, child container resources and metadata, deduplication, running image identity, live-data refusal, consumer shutdown, stop/inspection failures, recursive-output exclusion\n'
