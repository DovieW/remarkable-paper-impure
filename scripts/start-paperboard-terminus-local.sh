#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
env_file="$REPOSITORY_ROOT/deploy/terminus/.env"
compose="$REPOSITORY_ROOT/deploy/terminus/compose.local.yml"
local_port="${TERMINUS_LOCAL_PORT:-2300}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
[[ -f "$env_file" && ! -L "$env_file" ]] || die "run scripts/init-paperboard-terminus.sh first"
[[ "$(stat -c '%a' "$env_file")" == 600 ]] || die "$env_file must have mode 0600"
[[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1024 && local_port <= 65535 )) || die "TERMINUS_LOCAL_PORT must be between 1024 and 65535"
"$REPOSITORY_ROOT/scripts/check-paperboard-host.sh"

TERMINUS_PUBLIC_URL="http://localhost:$local_port" \
  TERMINUS_LOCAL_PORT="$local_port" \
  docker compose --env-file "$env_file" -f "$compose" up -d

for _ in $(seq 1 180); do
  if curl --fail --silent "http://127.0.0.1:$local_port/up" >/dev/null 2>&1; then
    docker compose --env-file "$env_file" -f "$compose" ps
    printf 'Terminus is ready at http://localhost:%s (host loopback only).\n' "$local_port"
    exit 0
  fi
  sleep 1
done

docker compose --env-file "$env_file" -f "$compose" ps >&2
die "Terminus did not become healthy; inspect logs with docker compose --env-file deploy/terminus/.env -f deploy/terminus/compose.local.yml logs"
