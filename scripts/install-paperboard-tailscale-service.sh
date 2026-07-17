#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false
uninstall=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install a boot-persistent userspace Tailscale service on a Paper Pure.

Usage:
  install-paperboard-tailscale-service.sh [--host ALIAS] [--dry-run]
  install-paperboard-tailscale-service.sh [--host ALIAS] --uninstall

The service keeps Funnel disabled and privately forwards tailnet TCP port 22
to a loopback-only Dropbear socket. Uninstalling leaves Tailscale binaries,
state, and Paperboard configuration intact for manual operation.
EOF
}

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --uninstall) uninstall=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for command_name in ssh scp; do command -v "$command_name" >/dev/null || die "$command_name is required"; done
ssh -o BatchMode=yes -- "$host" 'test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64' \
  || die "target is not the verified Paper Pure"

if $dry_run; then
  if $uninstall; then
    echo "Would disable and remove the Paperboard Tailscale and loopback Dropbear units."
  else
    echo "Would install boot-persistent userspace Tailscale and loopback-only SSH units."
    echo "Would transition the currently running daemon after this SSH session returns."
  fi
  exit 0
fi

if $uninstall; then
  ssh -o BatchMode=yes -- "$host" '
    set -eu
    systemctl disable --now paperboard-tailscale-serve.service paperboard-tailscale.service dropbear-loopback.socket 2>/dev/null || true
    rm -f /etc/systemd/system/paperboard-tailscale.service \
      /etc/systemd/system/paperboard-tailscale-serve.service \
      /etc/systemd/system/dropbear-loopback.socket \
      /etc/systemd/system/dropbear-loopback@.service
    systemctl daemon-reload
    systemctl reset-failed paperboard-tailscale-serve.service paperboard-tailscale.service dropbear-loopback.socket 2>/dev/null || true
  '
  echo "Boot services removed. Use start-paperboard-tailscale.sh for manual operation."
  exit 0
fi

for unit in dropbear-loopback.socket paperboard-tailscale.service paperboard-tailscale-serve.service; do
  test -s "$ROOT/deploy/tablet/$unit" || die "missing unit: $unit"
done

stage="/home/root/.paperboard-tailscale-service-stage.$$.$RANDOM"
ssh -o BatchMode=yes -- "$host" "mkdir -m 700 -p '$stage'"
scp -q "$ROOT/deploy/tablet/dropbear-loopback.socket" \
  "$ROOT/deploy/tablet/paperboard-tailscale.service" \
  "$ROOT/deploy/tablet/paperboard-tailscale-serve.service" "$host:$stage/"

ssh -o BatchMode=yes -- "$host" sh -s -- "$stage" <<'REMOTE'
set -eu
stage=$1
base=/home/root/.local/share/paperboard/tailscale
test -x "$base/current/tailscaled" -a -x "$base/current/tailscale"
cp "$stage/dropbear-loopback.socket" /etc/systemd/system/dropbear-loopback.socket
cp "$stage/paperboard-tailscale.service" /etc/systemd/system/paperboard-tailscale.service
cp "$stage/paperboard-tailscale-serve.service" /etc/systemd/system/paperboard-tailscale-serve.service
chmod 0644 /etc/systemd/system/dropbear-loopback.socket \
  /etc/systemd/system/paperboard-tailscale.service \
  /etc/systemd/system/paperboard-tailscale-serve.service
ln -sfn /usr/lib/systemd/system/dropbear@.service /etc/systemd/system/dropbear-loopback@.service
rm -rf "$stage"
systemctl daemon-reload
systemctl enable dropbear-loopback.socket paperboard-tailscale.service paperboard-tailscale-serve.service >/dev/null

transition="$base/activate-systemd-service"
cat >"$transition" <<'TRANSITION'
#!/bin/sh
set -eu
base=/home/root/.local/share/paperboard/tailscale
pidfile="$base/runtime/tailscaled.pid"
if test -f "$pidfile" && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  kill "$(cat "$pidfile")" 2>/dev/null || true
  attempt=0
  while kill -0 "$(cat "$pidfile")" 2>/dev/null; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 30 || break
    sleep 0.1
  done
fi
rm -f "$base/runtime/tailscaled.sock" "$pidfile"
systemctl restart dropbear-loopback.socket || true
systemctl restart paperboard-tailscale.service
systemctl restart paperboard-tailscale-serve.service || true
rm -f "$0"
TRANSITION
chmod 0700 "$transition"
transition_unit="paperboard-tailscale-transition-$(date +%s)"
systemd-run --quiet --unit="$transition_unit" --on-active=2s "$transition"
REMOTE

echo "Boot units installed. Waiting for the private route to return after daemon handoff."
for attempt in {1..40}; do
  if ssh -o BatchMode=yes -o ConnectTimeout=2 -- "$host" \
    'systemctl is-active --quiet paperboard-tailscale.service && systemctl is-active --quiet paperboard-tailscale-serve.service && systemctl is-active --quiet dropbear-loopback.socket' \
    >/dev/null 2>&1; then
    echo "Paperboard Tailscale starts on boot and private SSH is active."
    exit 0
  fi
  sleep 1
done
die "service transition did not become reachable within 40 seconds"
