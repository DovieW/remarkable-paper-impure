#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
binary="${PAPERCTL_BINARY:-$REPOSITORY_ROOT/build/paperctl/paperctl-tap}"
remote_path="/home/root/.local/bin/paperctl-tap"
dry_run=false

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --host) host=${2:?missing host}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help)
      echo "Usage: deploy-paperctl.sh [--host ALIAS] [--dry-run]"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "$binary" ]] || die "tap helper not found: $binary"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
  'test "$(hostname)" = imx93-tatsu && mkdir -p /home/root/.local/bin' \
  || die "Paper Pure identity check failed"
$dry_run && { printf 'paperctl deploy dry run passed: %s\n' "$host"; exit 0; }
scp -q "$binary" "$host:$remote_path.new"
ssh -o BatchMode=yes "$host" \
  "test ! -f '$remote_path' || cp -p '$remote_path' '$remote_path.previous'; chmod 755 '$remote_path.new' && mv '$remote_path.new' '$remote_path'"
printf 'paperctl tap helper deployed: %s:%s\n' "$host" "$remote_path"
