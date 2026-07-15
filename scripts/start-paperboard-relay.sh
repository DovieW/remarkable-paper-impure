#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose="$root/deploy/relay/compose.yml"
env_file="$root/deploy/relay/.env"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
[[ -f "$env_file" ]] || die "run scripts/init-paperboard-relay.sh, then edit deploy/relay/.env"
[[ -s "$root/secrets/paperboard-master-key" ]] || die "missing relay master key"
[[ -s "$root/secrets/paperboard-admin-token" ]] || die "missing relay admin token"

docker compose --env-file "$env_file" -f "$compose" up -d --build
docker compose --env-file "$env_file" -f "$compose" exec -T tailscale tailscale serve --bg 8787
docker compose --env-file "$env_file" -f "$compose" ps
printf 'Relay is available locally at http://127.0.0.1:%s and privately through Tailscale Serve.\n' "${PAPERBOARD_LOCAL_PORT:-8787}"
printf 'After first enrollment, remove PAPERBOARD_TS_AUTHKEY from deploy/relay/.env; persistent Tailscale state is retained.\n'
