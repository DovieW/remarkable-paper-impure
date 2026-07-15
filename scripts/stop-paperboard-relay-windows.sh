#!/usr/bin/env bash

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
powershell.exe -NoProfile -NonInteractive -Command 'tailscale serve reset' | tr -d '\r'
docker compose --env-file "$root/deploy/relay/.env" -f "$root/deploy/relay/compose.windows-tailnet.yml" down
