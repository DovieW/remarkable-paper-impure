#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false
while (($#)); do
  case "$1" in
    --host) host="${2:?--host requires a value}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) echo 'Usage: rollback-paperterm.sh [--host HOST] [--dry-run]'; exit 0 ;;
    *) echo "rollback-paperterm.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<< "$identity"
[[ "$platform" == imx93-tatsu && "$architecture" == aarch64 ]] || { echo 'rollback-paperterm.sh: target is not a Paper Pure' >&2; exit 1; }
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' "$root/config/compatibility.json" "$os_version" || exit 1
if $dry_run; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'test -d /home/root/.local/share/paperterm/deployment-previous'
  echo 'PaperTerm rollback dry run passed.'
  exit 0
fi
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s <<'REMOTE'
set -eu
current=/home/root/xovi/exthome/appload/paperterm
previous=/home/root/.local/share/paperterm/deployment-previous
test -d "$previous" || { echo 'No previous PaperTerm release is available.' >&2; exit 1; }
failed=/home/root/.local/share/paperterm/deployment-failed.$$
test ! -d "$current" || mv "$current" "$failed"
mv "$previous" "$current"
rm -rf "$failed"
if test -s /home/root/.local/share/paperterm/deployment-previous-release; then
  mv /home/root/.local/share/paperterm/deployment-previous-release /home/root/.local/share/paperterm/current-release
fi
/home/root/xovi/start
REMOTE
echo 'PaperTerm rolled back. Open it physically from AppLoad to verify.'
