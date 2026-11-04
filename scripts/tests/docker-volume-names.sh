#!/usr/bin/env bash
set -euo pipefail

SCRIPTS=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
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
            --images) : ;;
            stop) : ;;
            *) exit 1 ;;
        esac ;;
    'volume inspect') [[ "${MISSING_VOLUME:-}" != "$3" ]] ;;
    'volume create') : ;;
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

printf '\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/backup.log" 2>&1
BACKUP=$(find backups -name .volume-map -exec dirname {} \;)
[[ -n "$BACKUP" ]]
for name in original_project_database nextcloud_aio_mastercontainer shared_storage 12345; do
    [[ -f "$BACKUP/volume_${name}_backup.tar.gz" ]]
done
! grep -q 'volume ls' "$TEST_ROOT/docker.log"

# Restore uses the saved physical names even if Compose now resolves other names.
printf 'services: {}\nvolumes: {}\n' > "$TEST_ROOT/config.yaml"
: > "$TEST_ROOT/docker.log"
printf '\n\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/restore.log" 2>&1
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
printf '\n\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/legacy.log" 2>&1
unset MISSING_VOLUME
grep -Fxq 'volume create nextcloud_aio_mastercontainer' "$TEST_ROOT/docker.log"
grep -Fq -- '-v nextcloud_aio_mastercontainer:/data' "$TEST_ROOT/docker.log"
grep -Fq -- '-v project_database:/data' "$TEST_ROOT/docker.log"
! grep -q 'project_nextcloud\|volume ls' "$TEST_ROOT/docker.log"

# An unknown archive must fail before stopping containers or writing data.
tar -czf "$BACKUP/volume_unknown_backup.tar.gz" -C "$TEST_ROOT/payload" .
: > "$TEST_ROOT/docker.log"
if printf '\n\nRESTORE\n' | bash "$SCRIPTS/restore-docker.sh" > "$TEST_ROOT/unknown.log" 2>&1; then
    echo 'FAIL: unknown volume accepted' >&2
    exit 1
fi
! grep -q ' stop$\|run --rm\|volume create' "$TEST_ROOT/docker.log"

# A missing source must not trigger an empty backup volume creation.
: > "$TEST_ROOT/docker.log"
export MISSING_VOLUME=nextcloud_aio_mastercontainer
if printf '\n' | bash "$SCRIPTS/backup-docker.sh" > "$TEST_ROOT/missing.log" 2>&1; then
    echo 'FAIL: missing source accepted' >&2
    exit 1
fi
! grep -q 'run --rm\|volume create' "$TEST_ROOT/docker.log"
printf 'PASS: exact names, explicit/external/default names, legacy archives, unknown archives, missing source\n'
