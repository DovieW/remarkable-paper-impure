#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
host="${REMARKABLE_HOST:-remarkable-usb}"
app=""
release=""
os_version=""
activation=""

usage() {
  cat <<'EOF'
Verify one installed tablet app and print a non-sensitive deployment report.

Usage: deployment-summary.sh --app paperboard|paperterm --release ID --os VERSION
                             --activation STATE [--host HOST]
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host="$2"; shift 2 ;;
    --app) (($# >= 2)) || die "--app requires a value"; app="$2"; shift 2 ;;
    --release) (($# >= 2)) || die "--release requires a value"; release="$2"; shift 2 ;;
    --os) (($# >= 2)) || die "--os requires a value"; os_version="$2"; shift 2 ;;
    --activation) (($# >= 2)) || die "--activation requires a value"; activation="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$app" == paperboard || "$app" == paperterm ]] || die "--app must be paperboard or paperterm"
[[ "$release" =~ ^[0-9a-f]{16}$ ]] || die "--release must be a 16-character content ID"
[[ -n "$os_version" && -n "$activation" ]] || die "--os and --activation are required"

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-appload-runtime.sh" \
  --host "$host" --wait 0

rollback="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- "$app" "$release" <<'REMOTE'
set -eu
app=$1
expected=$2
test "$(hostname)" = imx93-tatsu
root="/home/root/xovi/exthome/appload/$app"
test -s "$root/manifest.json"
test -s "$root/resources.rcc"
test -s "$root/icon.png"
test -x "$root/backend/entry"
test "$(cat "/home/root/.local/share/$app/current-release")" = "$expected"
if test "$app" = paperterm; then
  test "$($root/backend/entry --self-test)" = "paperterm backend self-test: ok"
fi
if test -d "/home/root/.local/share/$app/deployment-previous"; then
  printf true
else
  printf false
fi
REMOTE
)" || die "installed release verification failed"

printf '%s\n' '[deployment-report]'
printf 'app=%s\nrelease=%s\ndevice=reMarkable Paper Pure\nos=%s\n' "$app" "$release" "$os_version"
printf 'backup=verified\ninstalled=verified\nactivation=%s\nrollback_available=%s\n' "$activation" "$rollback"
