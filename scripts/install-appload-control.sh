#!/usr/bin/env bash
set -Eeuo pipefail

host=remarkable-usb
dry_run=false
while (($#)); do
  case "$1" in
    --host) host=${2:?missing host}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "usage: $0 [--host SSH_ALIAS] [--dry-run]" >&2; exit 2 ;;
  esac
done
readonly root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly artifact="$root/build/appload-control/appload/xovi/appload.so"
readonly remote=/home/root/xovi/extensions.d/appload.so

ssh -o BatchMode=yes -- "$host" 'test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64'
if $dry_run; then
  echo "Would back up and replace $remote, then restart the stock UI."
  exit 0
fi
test -f "$artifact" || { echo "build the reviewed adapter first" >&2; exit 1; }
stamp=$(date -u +%Y%m%dT%H%M%SZ)
scp -- "$artifact" "$host:/tmp/paperboard-appload.so"
ssh -- "$host" "set -eu
  install -d -m 0700 /home/root/.local/share/paperboard/backups
  cp '$remote' '/home/root/.local/share/paperboard/backups/appload.so.$stamp'
  install -m 0755 /tmp/paperboard-appload.so '$remote'
  rm -f /tmp/paperboard-appload.so
  systemctl restart xochitl"
echo "Installed. The tablet must be unlocked after the stock UI restart."
