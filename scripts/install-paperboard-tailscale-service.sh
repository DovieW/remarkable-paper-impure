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
Install Xovi-lifecycle-persistent private Tailscale SSH on a Paper Pure.

Usage:
  install-paperboard-tailscale-service.sh [--host ALIAS] [--dry-run]
  install-paperboard-tailscale-service.sh [--host ALIAS] --uninstall

The persistent scripts live under encrypted home storage. Every Xovi start
recreates transient systemd services plus a one-minute health timer, keeping
Funnel disabled and forwarding tailnet TCP port 22 to key-only loopback
Dropbear. Uninstalling retains Tailscale binaries, state, and Paperboard data.
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
    echo "Would remove the persistent private SSH helpers and Xovi lifecycle hook."
  else
    echo "Would install Xovi-lifecycle-persistent userspace Tailscale and loopback-only SSH."
    echo "Would add a one-minute health timer and transition the running private route."
  fi
  exit 0
fi

if $uninstall; then
  ssh -o BatchMode=yes -- "$host" '
    set -eu
    systemctl stop paperboard-tailscale-health.timer paperboard-tailscale-health.service \
      paperboard-tailscale-serve.service paperboard-tailscale.service \
      paperboard-dropbear-loopback.service 2>/dev/null || true
    rm -f /home/root/xovi/scripts/post-start/50-paperboard-private-ssh.sh \
      /home/root/.local/share/paperboard/tailscale/private-ssh-enabled \
      /home/root/.local/share/paperboard/tailscale/private-ssh-activate \
      /home/root/.local/share/paperboard/tailscale/private-ssh-health
  '
    echo "Private SSH lifecycle hooks removed. Use start-paperboard-tailscale.sh manually if needed."
  exit 0
fi

for helper in paperboard-private-ssh-activate.sh paperboard-private-ssh-health.sh; do
  test -s "$ROOT/deploy/tablet/$helper" || die "missing helper: $helper"
done

stage="/home/root/.paperboard-tailscale-service-stage.$$.$RANDOM"
ssh -o BatchMode=yes -- "$host" "mkdir -m 700 -p '$stage'"
scp -q "$ROOT/deploy/tablet/paperboard-private-ssh-activate.sh" \
  "$ROOT/deploy/tablet/paperboard-private-ssh-health.sh" "$host:$stage/"

ssh -o BatchMode=yes -- "$host" sh -s -- "$stage" <<'REMOTE'
set -eu
stage=$1
base=/home/root/.local/share/paperboard/tailscale
test -x "$base/current/tailscaled" -a -x "$base/current/tailscale"
cp "$stage/paperboard-private-ssh-activate.sh" "$base/private-ssh-activate"
cp "$stage/paperboard-private-ssh-health.sh" "$base/private-ssh-health"
chmod 0700 "$base/private-ssh-activate" "$base/private-ssh-health"
touch "$base/private-ssh-enabled"
chmod 0600 "$base/private-ssh-enabled"
mkdir -p /home/root/xovi/scripts/post-start
cat >/home/root/xovi/scripts/post-start/50-paperboard-private-ssh.sh <<'HOOK'
#!/bin/sh
set -eu
base=/home/root/.local/share/paperboard/tailscale
test -f "$base/private-ssh-enabled" || exit 0
unit="paperboard-private-ssh-activation-$(date +%s)-$$"
systemd-run --quiet --no-block --collect --unit "$unit" "$base/private-ssh-activate"
HOOK
chmod 0700 /home/root/xovi/scripts/post-start/50-paperboard-private-ssh.sh
rm -rf "$stage"
"$base/private-ssh-activate"
REMOTE

echo "Persistent helpers installed. Waiting for the private route to return after daemon handoff."
for attempt in {1..40}; do
  if ssh -o BatchMode=yes -o ConnectTimeout=2 -- "$host" \
    'systemctl is-active --quiet paperboard-tailscale.service && systemctl is-active --quiet paperboard-tailscale-serve.service && systemctl is-active --quiet paperboard-dropbear-loopback.service && systemctl is-active --quiet paperboard-tailscale-health.timer' \
    >/dev/null 2>&1; then
    echo "Paperboard private SSH is active and will be recreated after each Xovi start."
    exit 0
  fi
  sleep 1
done
die "private SSH transition did not become healthy within 40 seconds"
