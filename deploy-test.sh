#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --check ]]; then
    script_dir=$(dirname -- "${BASH_SOURCE[0]}")
    exec bash "$script_dir/restore-data.sh" "$@"
fi
if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'Usage: bash deploy-test.sh [--check] /path/to/snapshot\n' >&2
    exit 2
fi

snapshot=$(cd -- "$1" && pwd)
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
bash restore-data.sh "$snapshot"
docker compose --env-file .env up -d --wait --wait-timeout 240 console
docker compose --env-file .env exec -T console wget -qO- http://127.0.0.1/api/health >/dev/null
docker compose --env-file .env ps -a
printf 'Console and API are ready at http://localhost:6276.\n'
