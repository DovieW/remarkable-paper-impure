#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
device="${PAPERBOARD_DEVICE:-paper-pure}"
admin_token_file="$REPOSITORY_ROOT/secrets/paperboard-admin-token"
local_port="${TERMINUS_LOCAL_PORT:-2300}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || die "this helper takes no arguments"
[[ -f "$admin_token_file" && ! -L "$admin_token_file" ]] || die "missing regular admin token file"
[[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1024 && local_port <= 65535 )) || die "invalid TERMINUS_LOCAL_PORT"

read -r -s -p "Terminus device ID/MAC (input hidden): " upstream_device
printf '\n'
[[ -n "$upstream_device" ]] || die "device ID cannot be empty"

PAPERBOARD_ADMIN_TOKEN="$(<"$admin_token_file")" \
  pnpm --dir "$REPOSITORY_ROOT" --silent paperboard admin provider set \
    --device "$device" \
    --kind terminus \
    --base-url "http://host.docker.internal:$local_port" \
    --upstream-device "$upstream_device" \
    --allow-private-http
unset PAPERBOARD_ADMIN_TOKEN upstream_device

printf 'Local Terminus provider enabled for %s.\n' "$device"
