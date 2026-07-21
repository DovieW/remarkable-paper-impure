#!/bin/sh

set -eu

base=/home/root/.local/share/paperboard/tailscale
runtime="$base/runtime"
tailscale="$base/current/tailscale"
tailscaled="$base/current/tailscaled"
socket="$runtime/tailscaled.sock"
state="$base/state.json"
health="$base/private-ssh-health"
install_timer=${1:-install-timer}

test -x "$tailscale" -a -x "$tailscaled" -a -x "$health"
mkdir -p "$runtime"

if ! systemctl is-active --quiet paperboard-dropbear-loopback.service; then
    systemctl reset-failed paperboard-dropbear-loopback.service 2>/dev/null || true
    rm -f /run/paperboard-dropbear.pid
    systemd-run --quiet --collect --unit=paperboard-dropbear-loopback \
        --property=Restart=always --property=RestartSec=5 \
        /usr/sbin/dropbear -F -E -G root -s -j -k \
        -P /run/paperboard-dropbear.pid -p 127.0.0.1:2222 \
        -r /etc/dropbear/dropbear_ed25519_host_key
fi

if ! systemctl is-active --quiet paperboard-tailscale.service; then
    systemctl reset-failed paperboard-tailscale.service 2>/dev/null || true
    rm -f "$socket"
    systemd-run --quiet --collect --unit=paperboard-tailscale \
        --property=Restart=always --property=RestartSec=5 \
        --property=NoNewPrivileges=yes --property=PrivateTmp=yes \
        "$tailscaled" --state="$state" --socket="$socket" \
        --tun=userspace-networking --socks5-server=127.0.0.1:1055
fi

attempt=0
while :; do
    status=$($tailscale --socket="$socket" status --json 2>/dev/null || true)
    compact=$(printf '%s' "$status" | tr -d '[:space:]')
    if printf '%s' "$compact" | grep -q '"BackendState":"Running"' && \
       printf '%s' "$compact" | grep -q '"Online":true'; then
        break
    fi
    attempt=$((attempt + 1))
    test "$attempt" -lt 40 || exit 1
    sleep 1
done

systemctl stop paperboard-tailscale-serve.service 2>/dev/null || true
systemctl reset-failed paperboard-tailscale-serve.service 2>/dev/null || true
systemd-run --quiet --collect --unit=paperboard-tailscale-serve \
    --service-type=oneshot --remain-after-exit \
    --property=NoNewPrivileges=yes --property=PrivateTmp=yes \
    "$tailscale" --socket="$socket" serve --bg --yes \
    --tcp=22 tcp://127.0.0.1:2222

if test "$install_timer" != no-timer && \
   ! systemctl is-active --quiet paperboard-tailscale-health.timer; then
    systemctl reset-failed paperboard-tailscale-health.service \
        paperboard-tailscale-health.timer 2>/dev/null || true
    systemd-run --quiet --collect --unit=paperboard-tailscale-health \
        --on-active=60s --on-unit-active=60s "$health"
fi
