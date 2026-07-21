#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host=remarkable-usb
dry_run=false

usage() {
  cat <<'EOF'
Recover Xovi/AppLoad through the physical Paper Pure USB connection.

Usage: recover-appload-runtime.sh [--dry-run]

The recovery identifies the tablet, verifies compatibility, takes a backup,
resets only xochitl's failed state, schedules one Xovi start, then verifies the
complete AppLoad runtime invariant and application integrity. The tablet may
need to be unlocked after the UI restart.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<<"$identity"
[[ "$platform" == imx93-tatsu && "$architecture" == aarch64 ]] || die 'target is not a Paper Pure'
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' \
  "$ROOT/config/compatibility.json" "$os_version" || die "OS $os_version is not approved"

if $dry_run; then
  "$ROOT/scripts/backup.sh" --host "$host" --dry-run
  printf 'Recovery dry run passed; no tablet state was changed.\n'
  exit 0
fi

"$ROOT/scripts/backup.sh" --host "$host"
"$ROOT/scripts/restart-appload-runtime.sh" --host "$host"
"$ROOT/scripts/device-smoke-test.sh" --host "$host"
printf 'AppLoad recovery verified. Unlock the tablet if the UI requests it.\n'
