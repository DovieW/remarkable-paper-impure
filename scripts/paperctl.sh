#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"

usage() {
  cat <<'EOF'
Capture and control an unlocked Paper Pure through authenticated SSH.

Usage:
  paperctl.sh screenshot [LOCAL_PNG]
  paperctl.sh tap X Y
  paperctl.sh swipe X1 Y1 X2 Y2 [DURATION_MS]
  paperctl.sh status

Tap coordinates use the 1404x1872 screenshot space. This tool deliberately
does not unlock the tablet, enter a passcode, or expose a network service.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

(($# >= 1)) || { usage >&2; exit 2; }
command_name=$1
shift

case "$command_name" in
  screenshot)
    (($# <= 1)) || die "screenshot accepts at most one output path"
    output="${1:-$REPOSITORY_ROOT/captures/paperctl-$(date -u +%Y%m%dT%H%M%SZ).png}"
    remote_file="/home/root/.local/share/paperctl/current.png"
    ssh -o BatchMode=yes "$host" sh -s -- "$remote_file" <<'REMOTE'
set -eu
output=$1
mkdir -p "$(dirname "$output")"
rm -f "$output"
echo ">etakeScreenshot:$output,0" > /run/xovi-mb
test "$(cat /run/xovi-mb-out)" = success
for attempt in 1 2 3 4 5; do
  test -s "$output" && exit 0
  sleep 1
done
exit 1
REMOTE
    mkdir -p "$(dirname "$output")"
    scp -q "$host:$remote_file" "$output"
    printf '%s\n' "$output"
    ;;
  tap)
    (($# == 2)) || die "tap requires X and Y coordinates"
    ssh -o BatchMode=yes "$host" /home/root/.local/bin/paperctl-tap "$1" "$2"
    ;;
  swipe)
    (($# == 4 || $# == 5)) || die "swipe requires X1 Y1 X2 Y2 [DURATION_MS]"
    duration="${5:-600}"
    ssh -o BatchMode=yes "$host" /home/root/.local/bin/paperctl-tap "$1" "$2" "$3" "$4" "$duration"
    ;;
  status)
    (($# == 0)) || die "status accepts no arguments"
    ssh -o BatchMode=yes "$host" '
      printf "xochitl="; systemctl is-active xochitl.service
      printf "screenshot="; test -p /run/xovi-mb && echo ready || echo unavailable
      printf "tap-helper="; test -x /home/root/.local/bin/paperctl-tap && echo ready || echo unavailable
    '
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
