#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

config="$ROOT/secrets/tablet-bridge/ssh/config"
known_hosts="$ROOT/secrets/tablet-bridge/ssh/known_hosts"
dry_run=false
usb_host="${REMARKABLE_USB_HOST:-remarkable-usb}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --usb-host) (($# >= 2)) || die "--usb-host requires a value"; usb_host=$2; shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--usb-host HOST] [--dry-run]\n' "$PROGRAM_NAME"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$config" && -f "$known_hosts" ]] || die "provision the ignored tablet bridge configuration first"
ssh-keygen -F 10.11.99.1 -f "$known_hosts" >/dev/null 2>&1 \
  || die "the relay key store does not contain the USB-pinned tablet host key"

tablet_ip=""
if identity="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$usb_host" \
  'printf "%s|%s\n" "$(hostname)" "$(uname -m)"' 2>/dev/null)"; then
  [[ $identity == 'imx93-tatsu|aarch64' ]] \
    || die "the USB target is not an identified Paper Pure"
  tablet_ip="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$usb_host" \
    'tailscale ip -4 2>/dev/null || /home/root/.local/share/paperboard/tailscale/current/tailscale --socket=/home/root/.local/share/paperboard/tailscale/runtime/tailscaled.sock ip -4' 2>/dev/null)"
else
  command -v jq >/dev/null || die "USB is unavailable and jq is required for tailnet discovery"
  command -v powershell.exe >/dev/null || die "USB is unavailable and Windows PowerShell interop is required for tailnet discovery"
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
fi
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
