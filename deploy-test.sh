#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'Usage: bash deploy-test.sh /path/to/snapshot\n' >&2
    exit 2
fi

snapshot=$(cd -- "$1" && pwd)
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
bash restore-data.sh "$snapshot"
docker compose --env-file .env up -d --wait --wait-timeout 240 console
docker compose --env-file .env ps -a
