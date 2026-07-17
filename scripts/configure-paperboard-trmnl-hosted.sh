#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="${PAPERBOARD_DEVICE:-paper-pure}"
admin_token_file="$repo_root/secrets/paperboard-admin-token"

usage() {
  cat <<'EOF'
Usage: scripts/configure-paperboard-trmnl-hosted.sh

Securely enables the TRMNL Hosted BYOD provider. The script prompts for the
TRMNL device ID locally and the Device API Key without echoing it. The key is
stored only in a mode-0600 temporary file and removed on exit. The script talks
only to Paperboard's loopback admin listener; the credential is encrypted by
the relay and never sent to the tablet.
EOF
}

if [[ $# -gt 0 ]]; then
  usage
  [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help") ]] && exit 0
  exit 2
fi

read -r -s -p "TRMNL device ID/MAC (input hidden): " upstream_device
printf '\n'
[[ -n "$upstream_device" ]] || { echo "UPSTREAM_DEVICE_ID cannot be empty" >&2; exit 2; }
[[ -f "$admin_token_file" ]] || { echo "Missing $admin_token_file" >&2; exit 1; }
command -v pnpm >/dev/null || { echo "pnpm is required" >&2; exit 1; }

umask 077
token_file="$(mktemp "${TMPDIR:-/tmp}/paperboard-trmnl-token.XXXXXX")"
cleanup() {
  unset access_token upstream_device PAPERBOARD_ADMIN_TOKEN
  rm -f "$token_file"
}
trap cleanup EXIT INT TERM

read -r -s -p "TRMNL Device API Key (input hidden): " access_token
printf '\n'
[[ -n "$access_token" ]] || { echo "The API key cannot be empty" >&2; exit 2; }
printf '%s' "$access_token" > "$token_file"
unset access_token

PAPERBOARD_ADMIN_TOKEN="$(<"$admin_token_file")" \
  pnpm --dir "$repo_root" --silent paperboard admin provider set \
    --device "$device" \
    --kind trmnl-hosted \
    --base-url https://trmnl.com \
    --upstream-device "$upstream_device" \
    --access-token-file "$token_file"

echo "TRMNL Hosted BYOD provider enabled for $device."
