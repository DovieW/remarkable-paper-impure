#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
env_file="$REPOSITORY_ROOT/deploy/terminus/.env"
[[ -f "$env_file" ]] || { printf 'Terminus env file is not initialized.\n' >&2; exit 1; }
docker compose --env-file "$env_file" -f "$REPOSITORY_ROOT/deploy/terminus/compose.local.yml" down
printf 'Local Terminus stopped; persistent volumes were retained.\n'
