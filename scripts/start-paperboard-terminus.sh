#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
env_file="$REPOSITORY_ROOT/deploy/terminus/.env"
compose="$REPOSITORY_ROOT/deploy/terminus/compose.yml"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
[[ -f "$env_file" && ! -L "$env_file" ]] || die "run scripts/init-paperboard-terminus.sh first"
[[ "$(stat -c '%a' "$env_file")" == 600 ]] || die "$env_file must have mode 0600"
"$REPOSITORY_ROOT/scripts/check-paperboard-host.sh"

public_url="$(sed -n 's/^TERMINUS_PUBLIC_URL=//p' "$env_file")"
auth_key="$(sed -n 's/^TERMINUS_TS_AUTHKEY=//p' "$env_file")"
[[ "$public_url" == https://* && "$public_url" != *example-tailnet* ]] || die "set a real private TERMINUS_PUBLIC_URL"
[[ "$auth_key" == tskey-* ]] || die "set a scoped Tailscale auth key in the ignored env file"

docker compose --env-file "$env_file" -f "$compose" up -d
docker compose --env-file "$env_file" -f "$compose" ps
printf 'Terminus is starting behind private Tailscale Serve. Complete first-user setup only from the tailnet URL.\n'
