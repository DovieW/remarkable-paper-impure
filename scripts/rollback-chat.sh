#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) printf 'Usage: %s [--host remarkable-usb] [--dry-run]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if ! $dry_run && [[ $host != remarkable-usb ]]; then
  die 'Chat rollback requires --host remarkable-usb because AppLoad must restart'
fi
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<<"$identity"
[[ $platform == imx93-tatsu && $architecture == aarch64 ]] || die 'target is not a Paper Pure'
node -e 'const c=require(process.argv[1]);process.exit(c.approved_os[process.argv[2]]?0:1)' "$ROOT/config/compatibility.json" "$os_version" \
  || die "OS $os_version is not approved"

if $dry_run; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'test -d /home/root/.local/share/chat/deployment-previous'
  printf 'Chat rollback dry run passed.\n'
  exit 0
fi

"$ROOT/scripts/backup.sh" --host "$host"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh <<'REMOTE'
set -eu
current=/home/root/xovi/exthome/appload/chat
previous=/home/root/.local/share/chat/deployment-previous
test -d "$previous" || { echo 'No previous Chat release is available.' >&2; exit 1; }
if ps | grep -F 'backend/entry /tmp/chat.sock' | grep -v grep >/dev/null; then
  echo 'Chat is running. Exit it before rollback.' >&2
  exit 1
fi
failed=/home/root/.local/share/chat/deployment-failed.$$
test ! -d "$current" || mv "$current" "$failed"
mv "$previous" "$current"
rm -rf "$failed"
if test -s /home/root/.local/share/chat/deployment-previous-release; then
  mv /home/root/.local/share/chat/deployment-previous-release /home/root/.local/share/chat/current-release
fi
REMOTE
"$ROOT/scripts/restart-appload-runtime.sh" --host "$host"
printf 'Chat rolled back. Open it physically from AppLoad to verify.\n'
