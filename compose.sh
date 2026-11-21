#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export MSYS2_ARG_CONV_EXCL='*'
exec docker compose --env-file .env -f compose.yaml "$@"
