#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
host="${REMARKABLE_HOST:-remarkable-usb}"
wait_seconds=45
after_pid=0
require_paperboard=true
require_paperterm=true

usage() {
  cat <<'EOF'
Verify that the Paper Pure UI is actively running through Xovi and AppLoad.

Usage: verify-appload-runtime.sh [--host HOST] [--wait SECONDS]
                                  [--after-pid PID]
                                  [--allow-missing-app APP]

The check is read-only. It waits for a UI restart to settle, then requires an
active Xovi-injected xochitl process, the Xovi message broker, installed
Paperboard and PaperTerm manifests, and a read-only root filesystem.

--after-pid requires xochitl to have a different process ID, proving that a
scheduled UI restart actually completed. --allow-missing-app accepts
paperboard or paperterm and is reserved for that application's uninstall path.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host="$2"; shift 2 ;;
    --wait) (($# >= 2)) || die '--wait requires a value'; wait_seconds="$2"; shift 2 ;;
    --after-pid) (($# >= 2)) || die '--after-pid requires a value'; after_pid="$2"; shift 2 ;;
    --allow-missing-app)
      (($# >= 2)) || die '--allow-missing-app requires a value'
      case "$2" in
        paperboard) require_paperboard=false ;;
        paperterm) require_paperterm=false ;;
        *) die '--allow-missing-app must be paperboard or paperterm' ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die '--wait must be a nonnegative integer'
[[ "$after_pid" =~ ^[0-9]+$ ]] || die '--after-pid must be a nonnegative integer'
((wait_seconds <= 120)) || die '--wait cannot exceed 120 seconds'
command -v ssh >/dev/null || die 'ssh is required'

ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
deadline=$((SECONDS + wait_seconds))
while :; do
  if ssh "${ssh_options[@]}" "$host" sh -s -- \
    "$after_pid" "$require_paperboard" "$require_paperterm" <<'REMOTE' >/dev/null 2>&1
set -eu
after_pid=$1
require_paperboard=$2
require_paperterm=$3
test "$(hostname)" = imx93-tatsu
test "$(uname -m)" = aarch64
test "$(systemctl is-active xochitl.service)" = active
pid=$(systemctl show --property MainPID --value xochitl.service)
test "$pid" -gt 1
test "$after_pid" -eq 0 || test "$pid" -ne "$after_pid"
tr '\0' '\n' < "/proc/$pid/environ" | grep -qx 'LD_PRELOAD=/home/root/xovi/xovi.so'
test -p /run/xovi-mb
test -s /home/root/xovi/extensions.d/appload.so
grep -Fq '/home/root/xovi/extensions.d/appload.so' "/proc/$pid/maps"
test "$require_paperboard" = false || test -s /home/root/xovi/exthome/appload/paperboard/manifest.json
test "$require_paperterm" = false || test -s /home/root/xovi/exthome/appload/paperterm/manifest.json
mount | grep -Eq '^/dev/mmcblk0p3 on / type ext4 \(ro[,)]'
REMOTE
  then
    printf 'PASS  Xovi/AppLoad runtime invariant is healthy on Paper Pure.\n'
    exit 0
  fi
  ((SECONDS < deadline)) || break
  sleep 5
done

die 'Xovi/AppLoad runtime invariant did not become healthy'
