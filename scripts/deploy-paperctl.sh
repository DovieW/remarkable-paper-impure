#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
binary="${PAPERCTL_BINARY:-$REPOSITORY_ROOT/build/paperctl/paperctl-tap}"
remote_path="/home/root/.local/bin/paperctl-tap"

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

[[ -x "$binary" ]] || die "tap helper not found: $binary"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
  'test "$(hostname)" = imx93-tatsu && mkdir -p /home/root/.local/bin' \
  || die "Paper Pure identity check failed"
scp -q "$binary" "$host:$remote_path.new"
ssh -o BatchMode=yes "$host" \
  "chmod 755 '$remote_path.new' && mv '$remote_path.new' '$remote_path'"
printf 'paperctl tap helper deployed: %s:%s\n' "$host" "$remote_path"
