#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

config="$ROOT/secrets/tablet-bridge/ssh/config"
known_hosts="$ROOT/secrets/tablet-bridge/ssh/known_hosts"
dry_run=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n' "$PROGRAM_NAME"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"
command -v powershell.exe >/dev/null || die "Windows PowerShell interop is required"
[[ -f "$config" && -f "$known_hosts" ]] || die "provision the ignored tablet bridge configuration first"
ssh-keygen -F 10.11.99.1 -f "$known_hosts" >/dev/null 2>&1 \
  || die "the relay key store does not contain the USB-pinned tablet host key"

status_file="$(mktemp)"
trap 'rm -f "$status_file"' EXIT INT TERM
powershell.exe -NoProfile -NonInteractive -Command '& tailscale.exe status --json' \
  | tr -d '\r' >"$status_file"

mapfile -t candidates < <(jq -r '
  .Peer[]
  | select(.Online == true)
  | select((.HostName // "") | test("remarkable|paper"; "i"))
  | .TailscaleIPs[0]
' "$status_file")
((${#candidates[@]} == 1)) || die "expected exactly one online Paper Pure tailnet peer"
tablet_ip=${candidates[0]}
[[ "$tablet_ip" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
  || die "the selected tablet endpoint is not a Tailscale IPv4 address"

if $dry_run; then
  echo "Would point the ignored relay SSH profile at the unique online tablet peer."
  echo "Would retain strict checking against the USB-pinned host key."
  exit 0
fi

temporary="${config}.new.$$"
awk -v endpoint="$tablet_ip" '
  BEGIN { alias_written = 0 }
  /^[[:space:]]*HostName[[:space:]]+/ { print "  HostName " endpoint; next }
  /^[[:space:]]*HostKeyAlias[[:space:]]+/ { print "  HostKeyAlias 10.11.99.1"; alias_written = 1; next }
  /^[[:space:]]*User[[:space:]]+/ && !alias_written {
    print "  HostKeyAlias 10.11.99.1"
    alias_written = 1
  }
  { print }
' "$config" >"$temporary"
# The host-side secrets tree is mode 0700. The read-only bind mount itself must
# remain readable after the container entrypoint drops supplementary groups.
chmod 644 "$temporary"
mv "$temporary" "$config"

echo "Relay SSH profile now uses the private tablet route and the USB-pinned host key."
