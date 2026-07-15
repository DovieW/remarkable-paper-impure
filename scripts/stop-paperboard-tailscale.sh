#!/usr/bin/env bash

set -Eeuo pipefail
host="${REMARKABLE_HOST:-remarkable-usb}"
if [[ ${1:-} == --host && -n ${2:-} ]]; then host=$2; shift 2; fi
(($# == 0)) || { printf 'Usage: %s [--host HOST]\n' "${0##*/}" >&2; exit 2; }

ssh "$host" sh -s <<'REMOTE'
set -eu
base=/home/root/.local/share/paperboard/tailscale
pidfile="$base/runtime/tailscaled.pid"
if ! test -f "$pidfile"; then echo "Paperboard Tailscale is not running."; exit 0; fi
pid=$(cat "$pidfile")
expected=$(readlink -f "$base/current/tailscaled")
actual=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
test "$actual" = "$expected" || { echo "Refusing to stop unexpected process $pid." >&2; exit 1; }
kill "$pid"
rm -f "$pidfile" "$base/runtime/tailscaled.sock"
echo "Paperboard Tailscale stopped."
REMOTE
