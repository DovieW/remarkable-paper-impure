#!/usr/bin/env bash
set -Eeuo pipefail
readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; readonly ROOT
host="${REMARKABLE_HOST:-remarkable-usb}"; bundle="${CHAT_BUILD_DIR:-$ROOT/build/chat-tatsu}"; dry_run=false; restart=true
die(){ printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do case "$1" in --host)host="$2";shift 2;;--bundle)bundle="$2";shift 2;;--dry-run)dry_run=true;shift;;--no-restart-xovi)restart=false;shift;;-h|--help)printf 'Usage: deploy-chat.sh [--host HOST] [--bundle DIRECTORY] [--dry-run] [--no-restart-xovi]\n';exit 0;;*)die "unknown argument: $1";;esac;done
$restart && ! $dry_run && [[ "$host" != remarkable-usb ]] && die "Xovi/AppLoad restarts require --host remarkable-usb"
for file in manifest.json resources.rcc icon.png backend/entry; do [[ -s "$bundle/$file" ]] || die "missing bundle file: $file"; done
release="$({
  sha256sum "$bundle/manifest.json" | cut -d' ' -f1
  sha256sum "$bundle/resources.rcc" | cut -d' ' -f1
  sha256sum "$bundle/backend/entry" | cut -d' ' -f1
  sha256sum "$bundle/icon.png" | cut -d' ' -f1
} | sha256sum | cut -c1-16)"
identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture image_version <<< "$identity"
[[ "$platform" == imx93-tatsu && "$architecture" == aarch64 ]] || die "unexpected target: $platform/$architecture"
node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1]));if(!d.approved_os[process.argv[2]])process.exit(1)' "$ROOT/config/compatibility.json" "$image_version" || die "OS $image_version is not approved"
printf 'Target: %s (%s, OS %s)\n' "$platform" "$architecture" "$image_version"
if $dry_run; then "$ROOT/scripts/backup.sh" --host "$host" --dry-run; exit 0; fi
"$ROOT/scripts/backup.sh" --host "$host"
stage="/home/root/.chat-stage.$$"; trap 'ssh -o BatchMode=yes "$host" "rm -rf -- $stage" >/dev/null 2>&1 || true' EXIT
ssh -o BatchMode=yes "$host" "rm -rf -- '$stage'; mkdir -m 700 -p '$stage/backend'"
scp -o BatchMode=yes "$bundle/manifest.json" "$bundle/resources.rcc" "$bundle/icon.png" "$host:$stage/"
scp -o BatchMode=yes "$bundle/backend/entry" "$host:$stage/backend/entry"
ssh -o BatchMode=yes "$host" sh -s -- "$stage" "$release" <<'REMOTE'
set -eu
stage=$1
release=$2
chmod 644 "$stage/manifest.json" "$stage/resources.rcc" "$stage/icon.png"; chmod 755 "$stage/backend/entry"
test -d /home/root/xovi/exthome/appload
mkdir -p /home/root/.local/share/chat
rm -rf /home/root/.local/share/chat/deployment-previous
test ! -d /home/root/xovi/exthome/appload/chat || mv /home/root/xovi/exthome/appload/chat /home/root/.local/share/chat/deployment-previous
rm -f /home/root/.local/share/chat/deployment-previous-release
test ! -s /home/root/.local/share/chat/current-release || mv /home/root/.local/share/chat/current-release /home/root/.local/share/chat/deployment-previous-release
mv "$stage" /home/root/xovi/exthome/appload/chat
printf '%s\n' "$release" > /home/root/.local/share/chat/current-release
REMOTE
trap - EXIT
if $restart; then "$ROOT/scripts/restart-appload-runtime.sh" --host "$host"; fi
"$ROOT/scripts/verify-appload-runtime.sh" --host "$host"
printf 'Chat deployed. Select Chat from AppLoad.\n'
"$ROOT/scripts/deployment-summary.sh" --host "$host" --app chat \
  --release "$release" --os "$image_version" --activation physical-only
