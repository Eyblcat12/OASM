#!/usr/bin/env bash
set -euo pipefail

check_only=false
if [[ ${1:-} == --check ]]; then
    check_only=true
    shift
fi
if [[ $# -ne 3 || ! -d $1 || ! -d $2 || ! $3 =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    printf 'Usage: bash migrate-upstream-data.sh [--check] SNAPSHOT UPSTREAM_COMPOSE_DIRECTORY NEW_PROJECT\n' >&2
    exit 2
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
snapshot=$(cd -- "$1" && pwd -P)
upstream=$(cd -- "$2" && pwd -P)
project=$3
export MSYS2_ARG_CONV_EXCL='*'

compose_path() {
    if [[ $OSTYPE == msys* ]]; then
        cygpath -am -- "$1"
    else
        printf '%s' "$1"
    fi
}

compose=(docker compose --project-directory "$(compose_path "$upstream")"
    --env-file "$(compose_path "$upstream/.env")" -p "$project"
    -f "$(compose_path "$upstream/docker-compose.yml")"
    -f "$(compose_path "$repo/compose.upstream-data.yaml")")

if [[ ! -s "$upstream/.env" || ! -s "$upstream/docker-compose.yml" || ! -s "$snapshot/SHA256SUMS" ]]; then
    printf 'Provide the upstream .env, docker-compose.yml and a snapshot with SHA256SUMS.\n' >&2
    exit 2
fi

# Check only the payload that is imported. Image, Redis and worker archives are unused.
manifest=$(awk '
  {
    name = $2
    sub(/^\*/, "", name)
    if (name ~ /^(postgres\.dump|rustfs-data\.tar\.gz|audit-archive\.tar\.gz|counts\.txt|workspace-id\.txt)$/) {
      if (seen[name]++) exit 1
      print
      count++
    }
  }
  END { if (count != 5) exit 1 }
' "$snapshot/SHA256SUMS") || {
    printf 'Checksum manifest must list each data payload exactly once.\n' >&2
    exit 2
}
(cd -- "$snapshot" && printf '%s\n' "$manifest" | sha256sum --check --strict)

workspace_id=$(tr -d '\r' < "$snapshot/workspace-id.txt")
if [[ ! $workspace_id =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    printf 'Invalid workspace ID in snapshot.\n' >&2
    exit 2
fi

# Resolve the target model without printing its interpolated credentials.
resources=$("${compose[@]}" config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
project = sys.argv[1]
services = config.get("services", {})
volumes = config.get("volumes", {})
for service, location, accepted in [
    ("postgres", "/var/lib/postgresql", {"pgdata", "pgdata18"}),
    ("rustfs", "/data", {"rustfs-data"}),
    ("core-api", "/app/audit-archive", {"audit-archive"}),
]:
    matches = [v for v in services.get(service, {}).get("volumes", [])
               if v.get("target") == location and v.get("type") == "volume"]
    if len(matches) != 1 or matches[0].get("source") not in accepted:
        sys.exit(f"Unexpected storage layout for {service} in the target Compose file.")
for key, volume in volumes.items():
    if volume.get("external") or volume.get("name") != f"{project}_{key}":
        sys.exit("The migration needs a clean project with project-scoped named volumes.")
    print("volume", volume["name"], sep="\t")
for network in config.get("networks", {}).values():
    if network.get("external"):
        sys.exit("The migration needs separate Compose networks.")
    print("network", network["name"], sep="\t")
for service in services.values():
    if name := service.get("container_name"):
        print("container", name, sep="\t")
' "$project")

current_containers=$("${compose[@]}" ps --all --quiet)
if [[ -n $current_containers ]]; then
    printf 'Destination project already contains containers: %s\n' "$project" >&2
    exit 2
fi
current_names=$(docker ps -a --format '{{.Names}}')
current_volumes=$(docker volume ls --format '{{.Name}}')
current_networks=$(docker network ls --format '{{.Name}}')
while IFS=$'\t' read -r kind name; do
    case $kind in
        container) existing=$current_names ;;
        volume) existing=$current_volumes ;;
        network) existing=$current_networks ;;
    esac
    if grep -Fxq "$name" <<< "$existing"; then
        printf 'Destination %s already exists: %s\n' "$kind" "$name" >&2
        exit 2
    fi
done <<< "$resources"

if "$check_only"; then
    printf 'Data checksums and empty destination verified for %s.\n' "$project"
    exit 0
fi

"${compose[@]}" up -d --no-deps --wait --wait-timeout 150 postgres
"${compose[@]}" exec -T postgres sh -ec \
    'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --exit-on-error --single-transaction --no-owner --no-privileges' \
    < "$snapshot/postgres.dump"

configuration_counts=()
if grep -q '^project_workflows=' "$snapshot/counts.txt"; then
    configuration_counts=(-v include_configuration_counts=1)
fi
actual_counts=$("${compose[@]}" exec -T postgres sh -ec \
    'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh \
    -v "project_workspace_id=$workspace_id" "${configuration_counts[@]}" < "$repo/counts.sql")
diff -u <(tr -d '\r' < "$snapshot/counts.txt") <(printf '%s\n' "$actual_counts")

activity=$("${compose[@]}" exec -T postgres sh -ec \
    'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT (SELECT count(*) FROM jobs WHERE status NOT IN ('completed', 'failed', 'cancelled'))
     + (SELECT count(*) FROM targets WHERE "scanSchedule" IS DISTINCT FROM 'disabled')
     + (SELECT count(*) FROM project_workflow_triggers);
SQL
)
if [[ $activity != 0 ]]; then
    printf 'Existing job or schedule state needs review before opening the target API. No other services were started.\n' >&2
    exit 2
fi

archive_image=$("${compose[@]}" config --images postgres)
for key in rustfs-data audit-archive; do
    volume="${project}_$key"
    docker volume create --label "com.docker.compose.project=$project" \
        --label "com.docker.compose.volume=$key" "$volume" >/dev/null
    docker run --rm --pull never --network none --read-only --user 0 --entrypoint tar \
        --mount "type=volume,source=$volume,target=/restore" -i "$archive_image" \
        -xzf - -C /restore < "$snapshot/$key.tar.gz"
done

printf 'Upstream data imported and counts matched for %s. Only PostgreSQL was started.\n' "$project"
