#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"
port="${PAPER_REMOTE_PORT:-4174}"

[[ $host =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || { echo "Invalid REMARKABLE_HOST alias." >&2; exit 2; }
[[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { echo "PAPER_REMOTE_PORT must be between 1 and 65535." >&2; exit 2; }

ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
  'test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64 && test -p /run/xovi-mb && test -x /home/root/.local/bin/paperctl-tap'

echo "Starting Paper Pure Remote on http://127.0.0.1:$port"
echo "The server is local-only. Press Ctrl+C to stop it."
cd "$ROOT"
exec env REMARKABLE_HOST="$host" PAPER_REMOTE_PORT="$port" pnpm --filter @paperboard/remote start
