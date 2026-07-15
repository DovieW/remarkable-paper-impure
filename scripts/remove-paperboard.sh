#!/usr/bin/env bash
set -euo pipefail

host=remarkable-usb
purge_data=false
dry_run=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Remove Paperboard from AppLoad.

Usage: remove-paperboard.sh [--host HOST] [--purge-data] [--dry-run]

By default the private config and last-good cache are retained. --purge-data
also deletes /home/root/.config/paperboard and Paperboard's private state.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --host) (( $# >= 2 )) || die "--host requires a value"; host=$2; shift 2 ;;
    --purge-data) purge_data=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s" "$(hostname)" "$(uname -m)"')"
IFS='|' read -r device_hostname architecture <<< "$identity"
[[ "$device_hostname" == imx93-tatsu && "$architecture" == aarch64 ]] \
  || die "unexpected target: $identity"

if $dry_run; then
  printf 'Would remove the Paperboard AppLoad bundle from %s.\n' "$host"
  $purge_data && printf 'Would also purge Paperboard config, cache, and rollback bundle.\n'
  exit 0
fi

ssh "${ssh_options[@]}" "$host" sh -s -- "$purge_data" <<'REMOTE'
set -eu
purge_data=$1
if ps | grep -F 'backend/entry /tmp/paperboard.sock' | grep -v grep >/dev/null; then
  echo 'Paperboard is running. Return to AppLoad before removing it.' >&2
  exit 1
fi
rm -rf /home/root/xovi/exthome/appload/paperboard
if test "$purge_data" = true; then
  rm -rf /home/root/.config/paperboard /home/root/.local/share/paperboard
fi
REMOTE
printf 'Paperboard removed. Use Reload in AppLoad to update the launcher.\n'
