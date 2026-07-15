#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
bundle_directory="${PAPERBOARD_BUILD_DIR:-$REPOSITORY_ROOT/build/paperboard-tatsu}"
dry_run=false
restart_xovi=false

usage() {
  cat <<'EOF'
Deploy a built Paperboard QML bundle to AppLoad on Paper Pure.

Usage: deploy-paperboard.sh [--host HOST] [--bundle DIRECTORY] [--restart-xovi] [--dry-run]
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --host)
      (($# >= 2)) || die "--host requires a value"
      host="$2"
      shift 2
      ;;
    --bundle)
      (($# >= 2)) || die "--bundle requires a value"
      bundle_directory="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --restart-xovi)
      restart_xovi=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

manifest="$bundle_directory/manifest.json"
resources="$bundle_directory/resources.rcc"
backend="$bundle_directory/backend/entry"
[[ -f "$manifest" ]] || die "AppLoad manifest not found: $manifest"
[[ -s "$resources" ]] || die "AppLoad resource bundle not found: $resources"
[[ -x "$backend" ]] || die "Paperboard backend not found or not executable: $backend"

for command_name in ssh scp; do
  command -v "$command_name" >/dev/null \
    || die "required command not found: $command_name"
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r device_hostname architecture image_version <<< "$identity"

[[ "$device_hostname" == imx93-tatsu ]] || die "unexpected device platform: $device_hostname"
[[ "$architecture" == aarch64 ]] || die "unexpected architecture: $architecture"
[[ "$image_version" == 3.27.* ]] || die "Paperboard spike is currently constrained to OS 3.27.x, found $image_version"

printf 'Target: %s (%s, OS %s)\n' "$device_hostname" "$architecture" "$image_version"
printf 'Bundle: %s\n' "$bundle_directory"

if $dry_run; then
  printf 'Dry run complete: no tablet files or services were changed.\n'
  exit 0
fi

remote_stage="/home/root/.paperboard-stage.$$"
ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" <<'REMOTE'
set -eu
stage=$1
rm -rf -- "$stage"
mkdir -m 700 "$stage"
mkdir -m 700 "$stage/backend"
REMOTE

cleanup() {
  ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" <<'REMOTE' >/dev/null 2>&1 || true
stage=$1
rm -rf -- "$stage"
REMOTE
}
trap cleanup EXIT INT TERM

scp "${ssh_options[@]}" "$manifest" "$host:$remote_stage/manifest.json"
scp "${ssh_options[@]}" "$resources" "$host:$remote_stage/resources.rcc"
scp "${ssh_options[@]}" "$backend" "$host:$remote_stage/backend/entry"

ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" "$restart_xovi" <<'REMOTE'
set -eu
stage=$1
restart_xovi=$2
chmod 644 "$stage/manifest.json" "$stage/resources.rcc"
chmod 700 "$stage/backend"
chmod 755 "$stage/backend/entry"
test -d /home/root/xovi/exthome/appload
mkdir -p /home/root/.local/share/paperboard
rm -rf /home/root/.local/share/paperboard/deployment-previous
if test -d /home/root/xovi/exthome/appload/paperboard; then
  mv /home/root/xovi/exthome/appload/paperboard \
    /home/root/.local/share/paperboard/deployment-previous
fi
mv "$stage" /home/root/xovi/exthome/appload/paperboard
if test "$restart_xovi" = true; then
  /home/root/xovi/start
fi
REMOTE
trap - EXIT INT TERM

if $restart_xovi; then
  printf 'Paperboard deployed. Allow at least 15 seconds for the stock UI and AppLoad to settle.\n'
else
  printf 'Paperboard deployed. Use AppLoad Reload before launching the new bundle.\n'
fi
