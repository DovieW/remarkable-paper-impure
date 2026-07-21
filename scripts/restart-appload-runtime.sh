#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host=remarkable-usb
allow_missing=()

usage() {
  cat <<'EOF'
Schedule one Xovi/AppLoad restart through the physical Paper Pure USB link.

Usage: restart-appload-runtime.sh [--host remarkable-usb]
                                  [--allow-missing-app APP]

The helper records the current xochitl PID, schedules Xovi independently of
the SSH session, and succeeds only after a different, healthy Xovi/AppLoad
runtime is active. APP may be paperboard or paperterm for its uninstall path.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host="$2"; shift 2 ;;
    --allow-missing-app)
      (($# >= 2)) || die '--allow-missing-app requires a value'
      [[ "$2" == paperboard || "$2" == paperterm ]] || die 'unsupported application'
      allow_missing+=(--allow-missing-app "$2")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$host" == remarkable-usb ]] || die 'Xovi/AppLoad restarts require physical USB via remarkable-usb'
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<<"$identity"
[[ "$platform" == imx93-tatsu && "$architecture" == aarch64 ]] || die 'target is not a Paper Pure'
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' \
  "$ROOT/config/compatibility.json" "$os_version" || die "OS $os_version is not approved"

before_pid="$(ssh "${ssh_options[@]}" "$host" \
  'systemctl show --property MainPID --value xochitl.service')"
[[ "$before_pid" =~ ^[0-9]+$ && "$before_pid" -gt 1 ]] || die 'xochitl has no valid active PID'

ssh "${ssh_options[@]}" "$host" sh <<'REMOTE'
set -eu
test "$(hostname)" = imx93-tatsu
systemctl reset-failed xochitl.service
unit="paperboard-xovi-restart-$(date +%s)-$$"
systemd-run --quiet --no-block --collect --unit "$unit" /home/root/xovi/start
REMOTE

"$ROOT/scripts/verify-appload-runtime.sh" --host "$host" --wait 60 \
  --after-pid "$before_pid" "${allow_missing[@]}"
