#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
bundle_directory="${PAPERTERM_BUILD_DIR:-$REPOSITORY_ROOT/build/paperterm-tatsu}"
dry_run=false
restart_xovi=true
compatibility_manifest="$REPOSITORY_ROOT/config/compatibility.json"

usage() {
  cat <<'EOF'
Transactionally install a built PaperTerm bundle on a Paper Pure.

Usage: deploy-paperterm.sh [--host HOST] [--bundle DIRECTORY] [--no-restart-xovi] [--dry-run]

An actual deployment creates and verifies a tablet backup first. PaperTerm is
not remotely launched because terminal launch is a physical-user boundary.
EOF
}
die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host="$2"; shift 2 ;;
    --bundle) (($# >= 2)) || die "--bundle requires a value"; bundle_directory="$2"; shift 2 ;;
    --no-restart-xovi) restart_xovi=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if $restart_xovi && ! $dry_run && [[ "$host" != remarkable-usb ]]; then
  die 'Xovi/AppLoad restarts require --host remarkable-usb; use --no-restart-xovi only for a verified backend-only update'
fi

manifest="$bundle_directory/manifest.json"
resources="$bundle_directory/resources.rcc"
backend="$bundle_directory/backend/entry"
icon="$bundle_directory/icon.png"
license="$bundle_directory/LICENSE.libvterm"
nerd_font="$bundle_directory/fonts/NotoMonoNerdFontMono-Regular.ttf"
nerd_font_license="$bundle_directory/LICENSE.nerd-fonts.txt"
[[ -f "$manifest" && -s "$resources" && -x "$backend" && -s "$icon" && -s "$license" \
  && -s "$nerd_font" && -s "$nerd_font_license" ]] || die "PaperTerm bundle is incomplete"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<< "$identity"
[[ "$platform" == imx93-tatsu && "$architecture" == aarch64 ]] || die "target is not a Paper Pure"
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' "$compatibility_manifest" "$os_version" \
  || die "OS $os_version is not approved"
release_id="$({
  sha256sum "$manifest" | cut -d' ' -f1
  sha256sum "$resources" | cut -d' ' -f1
  sha256sum "$backend" | cut -d' ' -f1
  sha256sum "$icon" | cut -d' ' -f1
  sha256sum "$license" | cut -d' ' -f1
  sha256sum "$nerd_font" | cut -d' ' -f1
  sha256sum "$nerd_font_license" | cut -d' ' -f1
} | sha256sum | cut -c1-16)"
printf 'PaperTerm release: %s\n' "$release_id"

if $dry_run; then
  "$REPOSITORY_ROOT/scripts/backup.sh" --host "$host" --dry-run
  printf 'Deployment dry run passed; no tablet files or services were changed.\n'
  exit 0
fi

"$REPOSITORY_ROOT/scripts/backup.sh" --host "$host"

remote_stage="/home/root/.paperterm-stage.$$"
ssh "${ssh_options[@]}" "$host" "rm -rf '$remote_stage'; mkdir -m 700 -p '$remote_stage/backend' '$remote_stage/fonts'"
cleanup() { ssh "${ssh_options[@]}" "$host" "rm -rf '$remote_stage'" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
scp "${ssh_options[@]}" "$manifest" "$resources" "$icon" "$license" "$nerd_font_license" "$host:$remote_stage/"
scp "${ssh_options[@]}" "$backend" "$host:$remote_stage/backend/entry"
scp "${ssh_options[@]}" "$nerd_font" "$host:$remote_stage/fonts/NotoMonoNerdFontMono-Regular.ttf"

ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" "$release_id" <<'REMOTE'
set -eu
stage=$1
release_id=$2
test "$(hostname)" = imx93-tatsu
chmod 644 "$stage/icon.png" "$stage/manifest.json" "$stage/resources.rcc" "$stage/LICENSE.libvterm" \
  "$stage/LICENSE.nerd-fonts.txt" "$stage/fonts/NotoMonoNerdFontMono-Regular.ttf"
chmod 755 "$stage/backend/entry"
"$stage/backend/entry" --self-test
test -d /home/root/xovi/exthome/appload
mkdir -p /home/root/.local/share/paperterm/releases
rm -rf "/home/root/.local/share/paperterm/releases/$release_id"
cp -a "$stage" "/home/root/.local/share/paperterm/releases/$release_id"
rm -rf /home/root/.local/share/paperterm/deployment-previous
rm -f /home/root/.local/share/paperterm/deployment-previous-release
if test -d /home/root/xovi/exthome/appload/paperterm; then
  mv /home/root/xovi/exthome/appload/paperterm /home/root/.local/share/paperterm/deployment-previous
  if test -s /home/root/.local/share/paperterm/current-release; then
    cp /home/root/.local/share/paperterm/current-release /home/root/.local/share/paperterm/deployment-previous-release
  fi
fi
mv "$stage" /home/root/xovi/exthome/appload/paperterm
printf '%s\n' "$release_id" > /home/root/.local/share/paperterm/current-release
REMOTE
trap - EXIT INT TERM
if $restart_xovi; then
  "$REPOSITORY_ROOT/scripts/restart-appload-runtime.sh" --host "$host"
fi
printf 'PaperTerm installed. Open it physically from AppLoad when ready.\n'
"$REPOSITORY_ROOT/scripts/deployment-summary.sh" --host "$host" --app paperterm \
  --release "$release_id" --os "$os_version" --activation physical-only
