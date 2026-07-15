#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
env_file="$REPOSITORY_ROOT/deploy/terminus/.env"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
command -v openssl >/dev/null || die "openssl is required"

if [[ -e "$env_file" ]]; then
  [[ -f "$env_file" && ! -L "$env_file" ]] || die "$env_file must be a regular file"
  chmod 600 "$env_file"
  printf 'Keeping existing ignored %s\n' "$env_file"
  exit 0
fi

app_secret="$(openssl rand -hex 48)"
database_password="$(openssl rand -hex 32)"
keyvalue_password="$(openssl rand -hex 32)"
cat > "$env_file" <<EOF
TERMINUS_PUBLIC_URL=https://terminus.example-tailnet.ts.net
TERMINUS_TS_HOSTNAME=terminus
TERMINUS_TS_AUTHKEY=
TERMINUS_APP_SECRET=$app_secret
TERMINUS_DATABASE_USER=terminus
TERMINUS_DATABASE_NAME=terminus_production
TERMINUS_DATABASE_PASSWORD=$database_password
TERMINUS_KEYVALUE_PASSWORD=$keyvalue_password
EOF
chmod 600 "$env_file"
printf 'Created ignored mode-0600 %s. Set its private Tailscale URL and auth key locally.\n' "$env_file"
