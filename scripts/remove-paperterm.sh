#!/usr/bin/env bash
set -Eeuo pipefail
host="${REMARKABLE_HOST:-remarkable-usb}"
purge_data=false
dry_run=false
die() { printf 'remove-paperterm.sh: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host="$2"; shift 2 ;;
    --purge-data) purge_data=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) echo 'Usage: remove-paperterm.sh [--host HOST] [--purge-data] [--dry-run]'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s" "$(hostname)" "$(uname -m)"')"
[[ "$identity" == "imx93-tatsu|aarch64" ]] || die 'target is not a Paper Pure'
if $dry_run; then
  echo 'Would remove the PaperTerm AppLoad bundle.'
  $purge_data && echo 'Would also permanently remove profiles, key, and rollback data.'
  exit 0
fi
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- "$purge_data" <<'REMOTE'
set -eu
purge=$1
if ps | grep -F 'backend/entry /tmp/paperterm.sock' | grep -v grep >/dev/null; then
  echo 'PaperTerm is running. Exit it before removal.' >&2
  exit 1
fi
rm -rf /home/root/xovi/exthome/appload/paperterm
if test "$purge" = true; then
  rm -rf /home/root/.config/paperterm /home/root/.local/share/paperterm
  rm -f /home/root/.ssh/paperterm_ed25519
fi
/home/root/xovi/start
REMOTE
echo 'PaperTerm removed.'
