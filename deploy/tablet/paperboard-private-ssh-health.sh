#!/bin/sh

set -eu

base=/home/root/.local/share/paperboard/tailscale
tailscale="$base/current/tailscale"
socket="$base/runtime/tailscaled.sock"
activate="$base/private-ssh-activate"
healthy=true

for unit in paperboard-dropbear-loopback.service paperboard-tailscale.service \
    paperboard-tailscale-serve.service; do
    systemctl is-active --quiet "$unit" || healthy=false
done
status=$($tailscale --socket="$socket" status --json 2>/dev/null || true)
compact=$(printf '%s' "$status" | tr -d '[:space:]')
printf '%s' "$compact" | grep -q '"BackendState":"Running"' || healthy=false
printf '%s' "$compact" | grep -q '"Online":true' || healthy=false

test "$healthy" = false || exit 0
systemctl stop paperboard-tailscale-serve.service paperboard-tailscale.service \
    paperboard-dropbear-loopback.service 2>/dev/null || true
rm -f "$socket" /run/paperboard-dropbear.pid
exec "$activate" no-timer
