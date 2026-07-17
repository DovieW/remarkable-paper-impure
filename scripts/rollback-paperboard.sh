#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${REMARKABLE_HOST:-remarkable-usb}"
activate=false
dry_run=false
while (($#)); do
  case "$1" in
    --host) host="${2:?--host requires a value}"; shift 2 ;;
    --activate) activate=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) echo 'Usage: rollback-paperboard.sh [--host ALIAS] [--activate] [--dry-run]'; exit 0 ;;
    *) printf 'rollback-paperboard.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
identity=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')
IFS='|' read -r platform architecture os_version <<<"$identity"
[[ $platform == imx93-tatsu && $architecture == aarch64 ]] || { echo 'rollback-paperboard.sh: target is not a Paper Pure' >&2; exit 1; }
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' "$root/config/compatibility.json" "$os_version" \
  || { echo "rollback-paperboard.sh: OS $os_version is not approved" >&2; exit 1; }
if $dry_run; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'test -d /home/root/.local/share/paperboard/deployment-previous'
  echo 'Rollback dry run complete: target and previous deployment are ready.'
  exit 0
fi
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s <<'REMOTE'
set -eu
current=/home/root/xovi/exthome/appload/paperboard
previous=/home/root/.local/share/paperboard/deployment-previous
test -d "$previous" || { echo 'No previous Paperboard release is available.' >&2; exit 1; }
failed=/home/root/.local/share/paperboard/deployment-failed.$$
test ! -e "$failed"
test ! -d "$current" || mv "$current" "$failed"
mv "$previous" "$current"
rm -rf "$failed"
if test -d /home/root/.local/share/paperboard/deployment-previous-2; then
  mv /home/root/.local/share/paperboard/deployment-previous-2 "$previous"
fi
REMOTE
if $activate; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" /home/root/xovi/start
  sleep 15
  REMARKABLE_HOST="$host" "$root/scripts/tablet-companion.sh" launch paperboard >/dev/null
fi
printf 'Paperboard rolled back on %s.\n' "$host"
