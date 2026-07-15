#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${REMARKABLE_HOST:-remarkable-usb}"
bundle="${CANVAS_BUILD_DIR:-$root/build/canvas-tatsu}"
dry=false
while (($#)); do case "$1" in --host) host=$2; shift 2;; --bundle) bundle=$2; shift 2;; --dry-run) dry=true; shift;; *) echo "unknown argument: $1" >&2; exit 1;; esac; done
for file in manifest.json resources.rcc backend/entry; do [[ -s "$bundle/$file" ]] || { echo "missing bundle file: $file" >&2; exit 1; }; done
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform arch version <<< "$identity"
[[ $platform == imx93-tatsu && $arch == aarch64 && $version == 3.27.* ]] || { echo "unsupported target: $identity" >&2; exit 1; }
$dry && { printf 'Canvas deploy dry run passed for OS %s.\n' "$version"; exit 0; }
stage="/home/root/.canvas-stage.$$"
ssh "$host" "rm -rf '$stage'; mkdir -m 700 -p '$stage/backend'"
trap 'ssh "$host" "rm -rf '\''$stage'\''" >/dev/null 2>&1 || true' EXIT
scp "$bundle/manifest.json" "$bundle/resources.rcc" "$host:$stage/"
scp "$bundle/backend/entry" "$host:$stage/backend/entry"
ssh "$host" sh -s -- "$stage" <<'REMOTE'
set -eu
stage=$1
chmod 644 "$stage/manifest.json" "$stage/resources.rcc"; chmod 755 "$stage/backend/entry"
test -d /home/root/xovi/exthome/appload
mkdir -p /home/root/.local/share/canvas
rm -rf /home/root/.local/share/canvas/deployment-previous
test ! -d /home/root/xovi/exthome/appload/canvas || mv /home/root/xovi/exthome/appload/canvas /home/root/.local/share/canvas/deployment-previous
mv "$stage" /home/root/xovi/exthome/appload/canvas
REMOTE
trap - EXIT
printf 'Canvas deployed. Use AppLoad Reload before launching it.\n'
