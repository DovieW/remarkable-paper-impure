#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
bundle_directory="${PAPERBOARD_BUILD_DIR:-$REPOSITORY_ROOT/build/paperboard-tatsu}"
dry_run=false
restart_xovi=true
activate=true
compatibility_manifest="$REPOSITORY_ROOT/config/compatibility.json"

usage() {
  cat <<'EOF'
Deploy a built Paperboard QML bundle to AppLoad on Paper Pure.

Usage: deploy-paperboard.sh [--host HOST] [--bundle DIRECTORY] [--no-restart-xovi] [--no-activate] [--dry-run]

The managed Xovi UI services restart by default so AppLoad cannot retain an
older QML frontend. An actual deployment creates and verifies a backup first.
Use --no-restart-xovi only for a backend-only release.
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
    --no-restart-xovi)
      restart_xovi=false
      shift
      ;;
    --no-activate)
      activate=false
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
icon="$bundle_directory/icon.png"
[[ -f "$manifest" ]] || die "AppLoad manifest not found: $manifest"
[[ -s "$resources" ]] || die "AppLoad resource bundle not found: $resources"
[[ -x "$backend" ]] || die "Paperboard backend not found or not executable: $backend"
[[ -s "$icon" ]] || die "Paperboard AppLoad icon not found: $icon"
[[ -f "$compatibility_manifest" ]] || die "compatibility manifest not found: $compatibility_manifest"

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
node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if (!data.approved_os[process.argv[2]]) process.exit(1)' \
  "$compatibility_manifest" "$image_version" || die "OS $image_version is not approved in config/compatibility.json"

release_id="$({
  sha256sum "$manifest" | cut -d' ' -f1
  sha256sum "$resources" | cut -d' ' -f1
  sha256sum "$backend" | cut -d' ' -f1
  sha256sum "$icon" | cut -d' ' -f1
} | sha256sum | cut -c1-16)"

printf 'Target: %s (%s, OS %s)\n' "$device_hostname" "$architecture" "$image_version"
printf 'Bundle: %s\n' "$bundle_directory"
printf 'Release: %s\n' "$release_id"

if $dry_run; then
  "$REPOSITORY_ROOT/scripts/backup.sh" --host "$host" --dry-run
  printf 'Dry run complete: no tablet files or services were changed.\n'
  exit 0
fi

"$REPOSITORY_ROOT/scripts/backup.sh" --host "$host"

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
scp "${ssh_options[@]}" "$icon" "$host:$remote_stage/icon.png"
scp "${ssh_options[@]}" "$backend" "$host:$remote_stage/backend/entry"

ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" "$restart_xovi" "$release_id" <<'REMOTE'
set -eu
stage=$1
restart_xovi=$2
release_id=$3
chmod 644 "$stage/icon.png" "$stage/manifest.json" "$stage/resources.rcc"
chmod 700 "$stage/backend"
chmod 755 "$stage/backend/entry"
test -d /home/root/xovi/exthome/appload
mkdir -p /home/root/.local/share/paperboard/releases
rm -rf "/home/root/.local/share/paperboard/releases/$release_id"
cp -a "$stage" "/home/root/.local/share/paperboard/releases/$release_id"
count=0
for release in $(ls -1dt /home/root/.local/share/paperboard/releases/* 2>/dev/null || true); do
  count=$((count + 1))
  test "$count" -le 3 || rm -rf -- "$release"
done
rm -rf /home/root/.local/share/paperboard/deployment-previous-2
test ! -d /home/root/.local/share/paperboard/deployment-previous || mv /home/root/.local/share/paperboard/deployment-previous /home/root/.local/share/paperboard/deployment-previous-2
if test -d /home/root/xovi/exthome/appload/paperboard; then
  mv /home/root/xovi/exthome/appload/paperboard \
    /home/root/.local/share/paperboard/deployment-previous
fi
mv "$stage" /home/root/xovi/exthome/appload/paperboard
printf '%s\n' "$release_id" > /home/root/.local/share/paperboard/current-release
if test "$restart_xovi" = true; then
  /home/root/xovi/start
fi
REMOTE
trap - EXIT INT TERM

if $activate; then
  if $restart_xovi; then
    # Xovi/AppLoad caches QML frontends independently of their backend. A
    # managed service restart is the only reliable way to load new resources.
    sleep 15
  elif ! REMARKABLE_HOST="$host" "$REPOSITORY_ROOT/scripts/tablet-companion.sh" return >/dev/null; then
    "$REPOSITORY_ROOT/scripts/rollback-paperboard.sh" --host "$host" --activate || true
    die "existing Paperboard process could not be stopped; rolled back"
  else
    # Backend-only releases do not require a Xovi restart, but allow AppLoad's
    # asynchronous frontend teardown to settle before reconnecting.
    sleep 3
  fi
  if ! REMARKABLE_HOST="$host" "$REPOSITORY_ROOT/scripts/tablet-companion.sh" launch paperboard >/dev/null; then
    "$REPOSITORY_ROOT/scripts/rollback-paperboard.sh" --host "$host" --activate || true
    die "Paperboard launch failed; rolled back"
  fi
  sleep 4
  foreground="$(REMARKABLE_HOST="$host" "$REPOSITORY_ROOT/scripts/tablet-companion.sh" status | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).foreground||"unknown")))')"
  if [[ "$foreground" != paperboard ]]; then
    "$REPOSITORY_ROOT/scripts/rollback-paperboard.sh" --host "$host" --activate || true
    die "Paperboard did not become foreground; rolled back"
  fi
fi

if $activate; then
  printf 'Paperboard deployed and activated transactionally.\n'
  activation=foreground
else
  printf 'Paperboard deployed transactionally without changing the foreground app.\n'
  activation=unchanged
fi
"$REPOSITORY_ROOT/scripts/deployment-summary.sh" --host "$host" --app paperboard \
  --release "$release_id" --os "$image_version" --activation "$activation"
