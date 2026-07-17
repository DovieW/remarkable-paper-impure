#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose="$root/deploy/relay/compose.windows-tailnet.yml"
env_file="$root/deploy/relay/.env"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
command -v powershell.exe >/dev/null || die "this deployment path requires WSL with Windows PowerShell interop"
[[ -f "$env_file" ]] || die "run scripts/init-paperboard-relay.sh, then edit deploy/relay/.env"
[[ -s "$root/secrets/paperboard-master-key" && -s "$root/secrets/paperboard-admin-token" ]] || die "relay secrets are missing"

docker compose --env-file "$env_file" -f "$compose" up -d --build
for _ in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -fsS http://127.0.0.1:8787/healthz >/dev/null || die "relay did not become healthy"
powershell.exe -NoProfile -NonInteractive -Command 'tailscale serve --bg http://127.0.0.1:8787' >/dev/null
docker compose --env-file "$env_file" -f "$compose" ps
printf 'Public API: private Windows Tailscale HTTPS\nLocal API: http://127.0.0.1:8787\nLocal-only administration: http://127.0.0.1:8788\n'
