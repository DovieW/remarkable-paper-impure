#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
host="${REMARKABLE_HOST:-remarkable-usb}"
hostname="paperboard"
serve_ssh=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --hostname) (($# >= 2)) || die "--hostname requires a value"; hostname=$2; shift 2 ;;
    --serve-ssh) serve_ssh=true; shift ;;
    -h|--help) printf 'Usage: %s [--host HOST] [--hostname NAME] [--serve-ssh]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$hostname" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "hostname is invalid"

ssh -t "$host" sh -s -- "$hostname" "$serve_ssh" <<'REMOTE'
set -eu
hostname=$1
serve_ssh=$2
base=/home/root/.local/share/paperboard/tailscale
binary="$base/current/tailscale"
daemon="$base/current/tailscaled"
runtime="$base/runtime"
socket="$runtime/tailscaled.sock"
pidfile="$runtime/tailscaled.pid"
test -x "$binary" -a -x "$daemon" || { echo "Install Tailscale first." >&2; exit 1; }
if systemctl is-active --quiet paperboard-tailscale.service 2>/dev/null; then
  if test "$serve_ssh" = true; then
    test -x "$base/private-ssh-activate" || {
      echo "The lifecycle-managed private SSH helper is missing." >&2
      exit 1
    }
    "$base/private-ssh-activate"
  fi
  echo "The Xovi-lifecycle-managed Paperboard Tailscale service is already active."
  exit 0
fi
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
if ! "$binary" --socket="$socket" status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
  echo "Complete the one-time Tailscale authentication shown below. This is an external authentication boundary."
  "$binary" --socket="$socket" up --hostname="$hostname"
fi
"$binary" --socket="$socket" status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"' || {
  echo "Tailscale did not reach the Running state." >&2
  exit 1
}
if test "$serve_ssh" = true; then
  wlan_ip=$(ip -4 -o addr show dev wlan0 scope global | awk 'NR==1 {split($4, part, "/"); print part[1]}')
  test -n "$wlan_ip" || { echo "Wi-Fi must be connected before enabling private SSH forwarding." >&2; exit 1; }
  "$binary" --socket="$socket" serve --bg --yes --tcp=22 "tcp://$wlan_ip:22" >/dev/null
  echo "Tailnet-only SSH forwarding is enabled. Funnel remains disabled."
fi
echo "Tailscale is connected (peer details redacted)."
echo "SOCKS5 proxy ready on loopback port 1055. No kernel routes were changed."
REMOTE
