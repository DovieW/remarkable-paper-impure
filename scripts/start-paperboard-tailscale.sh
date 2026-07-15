#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
host="${REMARKABLE_HOST:-remarkable-usb}"
hostname="paperboard"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --hostname) (($# >= 2)) || die "--hostname requires a value"; hostname=$2; shift 2 ;;
    -h|--help) printf 'Usage: %s [--host HOST] [--hostname NAME]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$hostname" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "hostname is invalid"

ssh -t "$host" sh -s -- "$hostname" <<'REMOTE'
set -eu
hostname=$1
base=/home/root/.local/share/paperboard/tailscale
binary="$base/current/tailscale"
daemon="$base/current/tailscaled"
runtime="$base/runtime"
socket="$runtime/tailscaled.sock"
pidfile="$runtime/tailscaled.pid"
test -x "$binary" -a -x "$daemon" || { echo "Install Tailscale first." >&2; exit 1; }
mkdir -p "$runtime"
chmod 700 "$runtime"
if test -f "$pidfile" && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  echo "Tailscale userspace daemon is already running."
else
  rm -f "$socket" "$pidfile"
  nohup "$daemon" \
    --state="$base/state.json" \
    --socket="$socket" \
    --tun=userspace-networking \
    --socks5-server=127.0.0.1:1055 \
    >"$runtime/tailscaled.log" 2>&1 &
  echo $! > "$pidfile"
  chmod 600 "$pidfile"
fi
tries=0
while ! test -S "$socket"; do
  tries=$((tries + 1))
  test "$tries" -lt 40 || { tail -30 "$runtime/tailscaled.log" >&2; exit 1; }
  sleep 1
done
if ! "$binary" --socket="$socket" status >/dev/null 2>&1; then
  echo "Complete the one-time Tailscale authentication shown below. This is an external authentication boundary."
  "$binary" --socket="$socket" up --hostname="$hostname"
fi
"$binary" --socket="$socket" status
echo "SOCKS5 proxy ready on loopback port 1055. No kernel routes were changed."
REMOTE
