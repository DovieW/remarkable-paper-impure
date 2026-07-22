#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"
purge_data=false
dry_run=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host=$2; shift 2 ;;
    --purge-data) purge_data=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) printf 'Usage: %s [--host remarkable-usb] [--purge-data] [--dry-run]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if ! $dry_run && [[ $host != remarkable-usb ]]; then
  die 'Chat removal requires --host remarkable-usb because AppLoad must restart'
fi
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s" "$(hostname)" "$(uname -m)"')"
[[ $identity == 'imx93-tatsu|aarch64' ]] || die 'target is not a Paper Pure'

if $dry_run; then
  printf 'Would back up and remove the Chat AppLoad bundle.\n'
  $purge_data && printf 'Would also permanently remove the unsent outbox and rollback bundle.\n'
  exit 0
fi

"$ROOT/scripts/backup.sh" --host "$host"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- "$purge_data" <<'REMOTE'
set -eu
purge=$1
if ps | grep -F 'backend/entry /tmp/chat.sock' | grep -v grep >/dev/null; then
  echo 'Chat is running. Exit it before removal.' >&2
  exit 1
fi
rm -rf /home/root/xovi/exthome/appload/chat
if test "$purge" = true; then
  rm -rf /home/root/.local/share/chat
fi
REMOTE
"$ROOT/scripts/restart-appload-runtime.sh" --host "$host" --allow-missing-app chat
printf 'Chat removed. OpenClaw conversations and relay cache were retained.\n'
