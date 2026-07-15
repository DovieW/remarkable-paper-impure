#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly VERSION="1.98.8"
readonly ARCHIVE_SHA256="53eb3ce89d062fd34e393d24a6c8ec08c769fede8eb77fe9c6e347ad4ae00f84"
readonly DOWNLOAD_URL="https://pkgs.tailscale.com/stable/tailscale_${VERSION}_arm64.tgz"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
usage() { printf 'Usage: %s [--host HOST] [--dry-run]\n' "$PROGRAM_NAME"; }
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for command_name in curl sha256sum tar ssh scp; do command -v "$command_name" >/dev/null || die "missing command: $command_name"; done
identity=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s" "$(hostname)" "$(uname -m)"')
[[ "$identity" == "imx93-tatsu|aarch64" ]] || die "unexpected target: $identity"
if $dry_run; then
  printf 'Would download Tailscale %s for arm64, verify SHA-256 %s, and install two binaries under the persistent home partition on %s.\n' "$VERSION" "$ARCHIVE_SHA256" "$host"
  exit 0
fi

download_dir="$root/build/downloads"
archive="$download_dir/tailscale_${VERSION}_arm64.tgz"
extract_dir="$root/build/tailscale-${VERSION}-arm64"
mkdir -p "$download_dir"
if [[ ! -f "$archive" ]] || [[ "$(sha256sum "$archive" | awk '{print $1}')" != "$ARCHIVE_SHA256" ]]; then
  temporary="$archive.part"
  rm -f "$temporary"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$temporary" "$DOWNLOAD_URL"
  printf '%s  %s\n' "$ARCHIVE_SHA256" "$temporary" | sha256sum --check --status || { rm -f "$temporary"; die "Tailscale archive checksum mismatch"; }
  mv "$temporary" "$archive"
fi
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir" --strip-components=1 "tailscale_${VERSION}_arm64/tailscale" "tailscale_${VERSION}_arm64/tailscaled"
[[ -x "$extract_dir/tailscale" && -x "$extract_dir/tailscaled" ]] || die "archive did not contain expected binaries"

stage="/home/root/.paperboard-tailscale-stage.$$"
ssh "$host" "rm -rf '$stage'; mkdir -m 700 '$stage'"
trap 'ssh "$host" "rm -rf '\''$stage'\''" >/dev/null 2>&1 || true' EXIT
scp -q "$extract_dir/tailscale" "$extract_dir/tailscaled" "$host:$stage/"
ssh "$host" sh -s -- "$stage" "$VERSION" <<'REMOTE'
set -eu
stage=$1
version=$2
base=/home/root/.local/share/paperboard/tailscale
install="$base/$version"
mkdir -p "$base"
chmod 700 "$base"
rm -rf "$install.new"
mkdir -m 700 "$install.new"
mv "$stage/tailscale" "$stage/tailscaled" "$install.new/"
chmod 755 "$install.new/tailscale" "$install.new/tailscaled"
rm -rf "$install"
mv "$install.new" "$install"
ln -sfn "$install" "$base/current"
rm -rf "$stage"
"$base/current/tailscale" version
REMOTE
trap - EXIT
printf 'Tailscale %s installed without changing routes, systemd, or the read-only root filesystem.\n' "$VERSION"
