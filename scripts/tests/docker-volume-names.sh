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
            stop) [[ "${FAIL_STOP:-0}" == 0 ]] ;;
            *) exit 1 ;;
        esac ;;
    'volume inspect') [[ "${MISSING_VOLUME:-}" != "$3" ]] ;;
    'volume create') : ;;
    'image inspect') [[ "${MISSING_IMAGE:-}" != "$3" ]] ;;
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
printf 'PASS: exact names, legacy archives, checkbox selection, cancellation, unavailable/missing/corrupt entries, bind/image/config selection, stop failure\n'
