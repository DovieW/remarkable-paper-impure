#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
secret_dir="$root/secrets"
mkdir -p "$secret_dir"

create_secret() {
  local path=$1 bytes=$2 prefix=${3:-}
  if [[ -e "$path" ]]; then
    printf 'Keeping existing %s\n' "$path"
    return
  fi
  if [[ -n "$prefix" ]]; then
    printf '%s%s\n' "$prefix" "$(openssl rand -base64 "$bytes" | tr -d '\n=/+' | head -c 48)" > "$path"
  else
    openssl rand -base64 "$bytes" > "$path"
  fi
  chmod 640 "$path"
  printf 'Created %s\n' "$path"
}

command -v openssl >/dev/null || { printf 'openssl is required.\n' >&2; exit 1; }
create_secret "$secret_dir/paperboard-master-key" 32
create_secret "$secret_dir/paperboard-admin-token" 36 "pb_admin_"

env_file="$root/deploy/relay/.env"
if [[ ! -e "$env_file" ]]; then
  cp "$root/deploy/relay/.env.example" "$env_file"
  host_gid=$(id -g)
  temporary="$env_file.tmp"
  awk -v gid="$host_gid" '{ if ($0 ~ /^PAPERBOARD_SECRET_GID=/) print "PAPERBOARD_SECRET_GID=" gid; else print }' "$env_file" > "$temporary"
  mv "$temporary" "$env_file"
  chmod 600 "$env_file"
  printf 'Created %s. Fill in the private Tailscale hostname and one-time auth key before launch.\n' "$env_file"
fi
