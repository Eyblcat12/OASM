#!/usr/bin/env bash
set -euo pipefail

check_only=false
if [[ ${1:-} == --check ]]; then
    check_only=true
    shift
fi
if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'Usage: bash restore-data.sh [--check] /path/to/snapshot\n' >&2
    exit 2
fi
snapshot=$(cd -- "$1" && pwd)
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./snapshot-common.sh

if [[ ! -s .env || ! -s "$snapshot/SHA256SUMS" ]]; then
    printf 'Configure .env and provide a completed snapshot with SHA256SUMS.\n' >&2
    exit 2
fi
for file in nginx.conf runtime-overrides/connectors.nuclei-60m.json branding/ncs-oasm-icon.png branding/ncs-oasm-wordmark.png branding/apply.sql; do
    if [[ ! -s "$file" ]]; then
        printf 'A deployment file is missing: %s\n' "$file" >&2
        exit 2
    fi
done

if [[ -f "$snapshot/image-ids.txt" ]]; then
    snapshot_files+=(image-ids.txt)
else
    snapshot_files+=(redis-data.tar.gz worker-state.tar.gz)
fi
for file in "${snapshot_files[@]}"; do
    if [[ ! -s "$snapshot/$file" ]]; then
        printf 'Snapshot is missing a required file: %s\n' "$file" >&2
        exit 2
    fi
done
if ! diff -u <(printf '%s\n' "${snapshot_files[@]}" | sort) <(
    sed -E 's/^[[:xdigit:]]{64} [ *]([a-z0-9.-]+)$/\1/' "$snapshot/SHA256SUMS" | sort
); then
    printf 'The checksum manifest must list exactly the required snapshot files.\n' >&2
    exit 2
fi
(cd -- "$snapshot" && sha256sum --check --strict SHA256SUMS)

if [[ -f "$snapshot/image-ids.txt" ]]; then
    mapfile -t image_records < "$snapshot/image-ids.txt"
    if [[ ${#image_records[@]} -ne ${#application_images[@]} ]]; then
        printf 'Unexpected number of application images in the snapshot.\n' >&2
        exit 2
    fi
    expected_ids=()
    for index in "${!application_images[@]}"; do
        tag=${application_images[$index]}
        record=${image_records[$index]}
        id=${record#"$tag "}
        if [[ $record != "$tag $id" || ! $id =~ ^sha256:[0-9a-f]{64}$ ]]; then
            printf 'Invalid snapshot image record for %s.\n' "$tag" >&2
            exit 2
        fi
        expected_ids+=("$id")
    done
else
    # The Windows PoC exporter pinned these image IDs before recording them in snapshots.
    expected_ids=(
        sha256:a93a128528c02b0acbb46902e27e62a2c56479fe12df0a3892492325e7125042
        sha256:d31b06be08d760220fa6ce1b123e6c2e9eddcd121c9338793dd3d3190550b154
    )
fi
workspace_id=$(tr -d '\r' < "$snapshot/workspace-id.txt")
if [[ ! $workspace_id =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    printf 'Invalid workspace ID in snapshot.\n' >&2
    exit 2
fi

project=$(read_project_name)
if "$check_only"; then
    printf 'Snapshot checksums and Compose configuration passed for %s.\n' "$project"
    exit 0
fi

existing_volumes=$(docker volume ls --format '{{.Name}}')
for volume in pgdata18 redis-data geoip-data "${data_volumes[@]}"; do
    if grep -Fxq "${project}_$volume" <<< "$existing_volumes"; then
        printf 'Destination volume already exists: %s_%s\n' "$project" "$volume" >&2
        exit 2
    fi
done
existing_containers=$("${compose[@]}" ps --all --quiet)
if [[ -n $existing_containers ]]; then
    printf 'Destination project already contains containers: %s\n' "$project" >&2
    exit 2
fi

docker image load < "$snapshot/oasm-images.tar"
for index in "${!application_images[@]}"; do
    tag=${application_images[$index]}
    id=$(docker image inspect --format '{{.Id}}' "$tag")
    if [[ $id != "${expected_ids[$index]}" ]]; then
        printf 'Loaded image does not match the snapshot: %s\n' "$tag" >&2
        exit 2
    fi
done
"${compose[@]}" pull --policy missing postgres redis rustfs geo-ip-database
archive_image=$("${compose[@]}" config --images postgres)

"${compose[@]}" up -d --wait --wait-timeout 150 postgres
"${compose[@]}" exec -T postgres pg_restore -U postgres -d open_asm \
    --exit-on-error --single-transaction --no-owner --no-privileges < "$snapshot/postgres.dump"

# Snapshots from older exports only include the initial inventory and jobs counts.
count_options=()
if grep -q '^project_workflows=' "$snapshot/counts.txt"; then
    count_options=(-v include_configuration_counts=1)
fi
actual_counts=$(count_snapshot_rows "$workspace_id" "${count_options[@]}")
diff -u <(tr -d '\r' < "$snapshot/counts.txt") <(printf '%s\n' "$actual_counts")

for volume in "${data_volumes[@]}"; do
    volume_name="${project}_$volume"
    docker volume create --label "com.docker.compose.project=$project" \
        --label "com.docker.compose.volume=$volume" "$volume_name" >/dev/null
    docker run --rm --pull never --network none --read-only --user 0 --entrypoint tar \
        --mount "type=volume,source=$volume_name,target=/restore" \
        -i "$archive_image" -xzf - -C /restore < "$snapshot/$volume.tar.gz"
done

"${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d open_asm < branding/apply.sql

printf 'Data restored and counts matched for %s.\n' "$project"
