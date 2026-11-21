#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! -d $1 || ! $2 =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    printf 'Usage: bash export-data.sh /existing/backup-directory workspace-uuid\n' >&2
    exit 2
fi
backup_dir=$(cd -- "$1" && pwd)
workspace_id=$2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./snapshot-common.sh
project=$(read_project_name)
archive_image=$("${compose[@]}" config --images postgres)

require_quiet_source() {
    local running
    running=$("${compose[@]}" ps --status running --services) || return
    if grep -Eq '^(core-api|rustfs|migration)$' <<< "$running"; then
        printf 'Stop core-api and rustfs and wait for migration to finish before exporting.\n' >&2
        return 1
    fi
    if ! grep -Fxq postgres <<< "$running"; then
        printf 'Keep PostgreSQL running while exporting.\n' >&2
        return 1
    fi
}

require_quiet_source
for volume in "${data_volumes[@]}"; do
    docker volume inspect "${project}_$volume" >/dev/null
done
workspace_exists=$(
    printf '%s\n' "SELECT 1 FROM public.workspaces WHERE id=:'project_workspace_id'::uuid;" |
        "${compose[@]}" exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 \
            -v "project_workspace_id=$workspace_id" -U postgres -d open_asm
)
if [[ $workspace_exists != 1 ]]; then
    printf 'The workspace ID does not exist in this database.\n' >&2
    exit 2
fi

image_services=(core-api console)
image_records=()
for index in "${!application_images[@]}"; do
    tag=${application_images[$index]}
    id=$(docker image inspect --format '{{.Id}}' "$tag")
    container=$("${compose[@]}" ps --all --quiet "${image_services[$index]}")
    if [[ -n $container ]]; then
        active_id=$(docker inspect --format '{{.Image}}' "$container")
        if [[ $id != "$active_id" ]]; then
            printf 'The deployed container and tagged image differ: %s\n' "$tag" >&2
            exit 2
        fi
    fi
    image_records+=("$tag $id")
done

umask 077
snapshot="$backup_dir/oasm-snapshot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -- "$snapshot"
before_counts=$(count_snapshot_rows "$workspace_id" -v include_configuration_counts=1)
printf '%s\n' "$workspace_id" > "$snapshot/workspace-id.txt"
printf '%s\n' "$before_counts" > "$snapshot/counts.txt"
printf '%s\n' "${image_records[@]}" > "$snapshot/image-ids.txt"
"${compose[@]}" exec -T postgres pg_dump -U postgres -d open_asm -Fc > "$snapshot/postgres.dump"
for volume in "${data_volumes[@]}"; do
    docker run --rm --pull never --network none --read-only --user 0 --entrypoint tar \
        --mount "type=volume,source=${project}_$volume,target=/source,readonly" \
        "$archive_image" -czf - -C /source . > "$snapshot/$volume.tar.gz"
done
require_quiet_source
after_counts=$(count_snapshot_rows "$workspace_id" -v include_configuration_counts=1)
if [[ $before_counts != "$after_counts" ]]; then
    printf 'Database counts changed during the export. Take a new snapshot after writers have stopped.\n' >&2
    exit 2
fi
docker image save "${application_images[@]}" > "$snapshot/oasm-images.tar"
(
    cd -- "$snapshot"
    sha256sum --binary "${snapshot_files[@]}" image-ids.txt > SHA256SUMS.tmp
    mv -- SHA256SUMS.tmp SHA256SUMS
)
printf 'Snapshot ready: %s\n' "$snapshot"
