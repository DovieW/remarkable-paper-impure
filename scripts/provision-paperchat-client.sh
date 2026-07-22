#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
client="openclaw-paperchat"
device=""
admin_url="${PAPERBOARD_ADMIN_URL:-http://127.0.0.1:8788}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --client) (($# >= 2)) || die "--client requires a value"; client=$2; shift 2 ;;
    --device) (($# >= 2)) || die "--device requires a value"; device=$2; shift 2 ;;
    --admin-url) (($# >= 2)) || die "--admin-url requires a value"; admin_url=$2; shift 2 ;;
    -h|--help) printf 'Usage: %s --device ID [--client ID] [--admin-url URL]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$client" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "client ID is invalid"
[[ "$device" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "device ID is invalid"
admin_token_file="$ROOT/secrets/paperboard-admin-token"
relay_env="$ROOT/deploy/relay/.env"
existing_client_env="$ROOT/secrets/clients/openclaw-main.env"
[[ -f "$admin_token_file" && ! -L "$admin_token_file" && -r "$admin_token_file" ]] || die "missing regular admin token file"
if [[ -n ${PAPERCHAT_RELAY_URL:-} ]]; then
  relay_url=$PAPERCHAT_RELAY_URL
elif [[ -f "$existing_client_env" && ! -L "$existing_client_env" && -r "$existing_client_env" ]]; then
  relay_url="$(sed -n 's/^PAPERBOARD_URL=//p' "$existing_client_env")"
else
  [[ -f "$relay_env" && ! -L "$relay_env" && -r "$relay_env" ]] || die "missing relay URL source"
  relay_url="$(sed -n 's/^PAPERBOARD_PUBLIC_BASE_URL=//p' "$relay_env")"
fi
[[ "$relay_url" == https://* ]] || die "PAPERBOARD_PUBLIC_BASE_URL is not configured"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT INT TERM
admin_token="$(<"$admin_token_file")"
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$client" '{id:$id,scopes:["chat:bridge:read","chat:bridge:write"]}')" \
  "$admin_url/admin/clients" > "$temporary/client.json"

client_token="$(jq -er '.token' "$temporary/client.json")"
mkdir -p "$ROOT/secrets/clients"
client_config="$ROOT/secrets/clients/$client.env"
printf 'PAPERCHAT_RELAY_URL=%q\nPAPERCHAT_RELAY_TOKEN=%q\nPAPERCHAT_DEVICE_ID=%q\n' \
  "$relay_url" "$client_token" "$device" > "$client_config"
chmod 600 "$client_config"
printf 'Provisioned scoped PaperChat client %s in an ignored mode-0600 environment file.\n' "$client"
