#!/usr/bin/env bash
set -euo pipefail

# Docker expects container paths verbatim, including when called from Git Bash.
export MSYS2_ARG_CONV_EXCL='*'

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
compose=(docker compose --env-file .env -f compose.yaml -p oasm-ti-siem-test)
archive_image='postgres@sha256:2ea8630df176ad090ec92136dee850397c5af8781e4bcf2e4162593691c61bbc'

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

(cd -- "$snapshot" && sha256sum --check SHA256SUMS)
files=(postgres.dump counts.txt workspace-id.txt rustfs-data.tar.gz audit-archive.tar.gz redis-data.tar.gz worker-state.tar.gz oasm-images.tar)
for file in "${files[@]}"; do
    if [[ ! -s "$snapshot/$file" ]] || ! grep -Fq "  $file" "$snapshot/SHA256SUMS"; then
        printf 'Snapshot is missing a checksummed file: %s\n' "$file" >&2
        exit 2
    fi
done
workspace_id=$(tr -d '\r' < "$snapshot/workspace-id.txt")
if [[ ! $workspace_id =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    printf 'Invalid workspace ID in snapshot.\n' >&2
    exit 2
fi

"${compose[@]}" config --quiet
if "$check_only"; then
    printf 'Snapshot checksums and Compose configuration passed.\n'
    exit 0
fi

for volume in pgdata18 rustfs-data audit-archive; do
    if docker volume inspect "oasm-ti-siem-test_$volume" >/dev/null 2>&1; then
        printf 'Destination volume already exists: %s\n' "$volume" >&2
        exit 2
    fi
done

docker image load < "$snapshot/oasm-images.tar"
[[ $(docker image inspect --format '{{.Id}}' local/oasm-api:poc-2e12e49) == sha256:a93a128528c02b0acbb46902e27e62a2c56479fe12df0a3892492325e7125042 ]]
[[ $(docker image inspect --format '{{.Id}}' local/oasm-console:poc-2e12e49) == sha256:d31b06be08d760220fa6ce1b123e6c2e9eddcd121c9338793dd3d3190550b154 ]]
"${compose[@]}" pull --policy missing postgres redis rustfs geo-ip-database

"${compose[@]}" up -d --wait --wait-timeout 150 postgres
"${compose[@]}" exec -T postgres pg_restore -U postgres -d open_asm \
    --exit-on-error --single-transaction --no-owner --no-privileges < "$snapshot/postgres.dump"

# Snapshots from older exports only include the initial inventory and jobs counts.
count_options=()
if grep -q '^project_workflows=' "$snapshot/counts.txt"; then
    count_options=(-v include_configuration_counts=1)
fi
actual_counts=$(
    "${compose[@]}" exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 "${count_options[@]}" \
        -v "project_workspace_id=$workspace_id" -U postgres -d open_asm < counts.sql
)
diff -u <(tr -d '\r' < "$snapshot/counts.txt") <(printf '%s\n' "$actual_counts")

for volume in rustfs-data audit-archive; do
    docker volume create --label com.docker.compose.project=oasm-ti-siem-test \
        --label "com.docker.compose.volume=$volume" "oasm-ti-siem-test_$volume" >/dev/null
    docker run --rm --pull never --network none --read-only --user 0 --entrypoint tar \
        --mount "type=volume,source=oasm-ti-siem-test_$volume,target=/restore" \
        -i "$archive_image" -xzf - -C /restore < "$snapshot/$volume.tar.gz"
done

"${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d open_asm < branding/apply.sql

printf 'Data restored and counts matched. Check test VM egress before starting the API and console.\n'
