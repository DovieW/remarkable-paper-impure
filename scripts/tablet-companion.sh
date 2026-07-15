#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"

usage() {
  cat <<'EOF'
Read semantic state from an unlocked Paper Pure without exposing arbitrary SSH.

Usage:
  tablet-companion.sh status
  tablet-companion.sh apps
  tablet-companion.sh screenshot [LOCAL_PNG]

The companion is intentionally read-only in v1. Paperboard navigation uses its
authenticated control API. This helper never unlocks, injects a passcode,
accepts shell text, or exposes raw tap coordinates.
EOF
}
die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
(($#)) || { usage >&2; exit 2; }
command=$1; shift
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)

case "$command" in
  status)
    (($# == 0)) || die "status accepts no arguments"
    ssh "${ssh_options[@]}" "$host" sh -s <<'REMOTE'
set -eu
platform=$(hostname); architecture=$(uname -m)
test "$platform" = imx93-tatsu && test "$architecture" = aarch64
foreground=stock
ps | grep -F 'backend/entry /tmp/paperboard.sock' | grep -v grep >/dev/null && foreground=paperboard
ps | grep -F 'backend/entry /tmp/canvas.sock' | grep -v grep >/dev/null && foreground=canvas
locked=unknown
if busctl --system get-property com.remarkable.powerManager /com/remarkable/powerManager com.remarkable.powerManager State >/dev/null 2>&1; then locked=false; fi
printf '{"platform":"%s","architecture":"%s","foreground":"%s","lock_state":"%s","screenshot":%s,"input_helper":%s}\n' \
  "$platform" "$architecture" "$foreground" "$locked" \
  "$(test -p /run/xovi-mb && echo true || echo false)" "$(test -x /home/root/.local/bin/paperctl-tap && echo true || echo false)"
REMOTE
    ;;
  apps)
    (($# == 0)) || die "apps accepts no arguments"
    ssh "${ssh_options[@]}" "$host" sh -s <<'REMOTE'
set -eu
test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64
printf '{"apps":['
first=true
for manifest in /home/root/xovi/exthome/appload/*/manifest.json; do
  test -f "$manifest" || continue
  id=${manifest%/manifest.json}; id=${id##*/}
  $first || printf ','; first=false
  printf '"%s"' "$id"
done
printf ']}\n'
REMOTE
    ;;
  screenshot)
    (($# <= 1)) || die "screenshot accepts at most one path"
    output=${1:-"$ROOT/captures/tablet-state-$(date -u +%Y%m%dT%H%M%SZ).png"}
    "$ROOT/scripts/paperctl.sh" screenshot "$output" >/dev/null
    printf '{"path":"%s"}\n' "$output"
    ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $command" ;;
esac
