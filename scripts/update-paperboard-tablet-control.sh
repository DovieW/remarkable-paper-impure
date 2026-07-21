#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false

usage() {
  cat <<'EOF'
Update only the installed forced-command implementation.

Usage: update-paperboard-tablet-control.sh [--host HOST] [--dry-run]

This preserves authorized_keys and the existing control key. It backs up the
installed command before replacing it with the reviewed implementation embedded
in install-paperboard-tablet-control.sh.
EOF
}
die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
ssh "${ssh_options[@]}" "$host" 'test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64 && test -x /home/root/.local/bin/paperboard-control'
$dry_run && { echo 'Tablet-control update dry run passed; no files were changed.'; exit 0; }

remote_script="$(mktemp)"
trap 'rm -f "$remote_script"' EXIT
sed -n '/^__REMOTE__$/,$p' "$ROOT/scripts/install-paperboard-tablet-control.sh" | sed '1d' > "$remote_script"
[[ -s "$remote_script" ]] || die 'could not extract the reviewed forced command'
scp "${ssh_options[@]}" "$remote_script" "$host:/home/root/.local/share/paperboard-control/paperboard-control.new"
ssh "${ssh_options[@]}" "$host" sh -s <<'REMOTE'
set -eu
current=/home/root/.local/bin/paperboard-control
staged=/home/root/.local/share/paperboard-control/paperboard-control.new
test -f "$staged"
cp -p "$current" /home/root/.local/share/paperboard-control/paperboard-control.previous
cp "$staged" "$current"
chmod 700 "$current"
rm -f "$staged"
SSH_ORIGINAL_COMMAND='paperboard-control status' "$current" >/dev/null
REMOTE
echo 'Forced-command implementation updated without changing authorized_keys.'
