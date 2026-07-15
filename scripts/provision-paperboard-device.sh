#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="${0##*/}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
device=""
client=""
admin_url="${PAPERBOARD_ADMIN_URL:-http://127.0.0.1:8788}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --device) (($# >= 2)) || die "--device requires a value"; device=$2; shift 2 ;;
    --client) (($# >= 2)) || die "--client requires a value"; client=$2; shift 2 ;;
    --admin-url) (($# >= 2)) || die "--admin-url requires a value"; admin_url=$2; shift 2 ;;
    -h|--help) printf 'Usage: %s --device ID --client ID [--admin-url URL]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$device" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "device ID is invalid"
[[ "$client" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "client ID is invalid"
admin_token_file="$root/secrets/paperboard-admin-token"
env_file="$root/deploy/relay/.env"
[[ -r "$admin_token_file" && -r "$env_file" ]] || die "initialize the relay first"
relay_url=$(sed -n 's/^PAPERBOARD_PUBLIC_BASE_URL=//p' "$env_file")
[[ "$relay_url" == https://* ]] || die "PAPERBOARD_PUBLIC_BASE_URL is not configured"

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT INT TERM
admin_token=$(<"$admin_token_file")
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $admin_token" -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$device" '{id:$id}')" \
  "$admin_url/admin/devices" > "$temporary/device.json"
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $admin_token" -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$client" '{id:$id,scopes:["cards:read","cards:write","cards:clear","status:read","paperboard:control","canvas:read","canvas:write"]}')" \
  "$admin_url/admin/clients" > "$temporary/client.json"
device_token=$(jq -er '.token' "$temporary/device.json")
client_token=$(jq -er '.token' "$temporary/client.json")

mkdir -p "$root/secrets/tablets" "$root/secrets/clients"
tablet_config="$root/secrets/tablets/$device.conf"
client_config="$root/secrets/clients/$client.env"
printf 'mode=relay\nrelay_url=%s\ndevice_id=%s\ndevice_token=%s\nproxy=socks5h://127.0.0.1:1055\npoll_wait=25\n' \
  "$relay_url" "$device" "$device_token" > "$tablet_config"
printf 'PAPERBOARD_URL=%q\nPAPERBOARD_TOKEN=%q\nPAPERBOARD_DEVICE=%q\n' \
  "$relay_url" "$client_token" "$device" > "$client_config"
chmod 600 "$tablet_config" "$client_config"
printf 'Provisioned device %s and client %s. Credentials were written only to ignored mode-0600 files under secrets/.\n' "$device" "$client"
