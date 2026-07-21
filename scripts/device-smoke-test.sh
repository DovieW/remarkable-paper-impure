#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
json=false

usage() {
  cat <<'EOF'
Run a read-only integrity and lifecycle smoke test against a Paper Pure.

Usage: device-smoke-test.sh [--host HOST] [--json]

This never launches an app, captures the display, injects input, or changes the
tablet. PaperTerm is checked only through its offline backend self-test.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host="$2"; shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for command_name in node scp ssh; do
  command -v "$command_name" >/dev/null || die "required command not found: $command_name"
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r platform architecture os_version <<<"$identity"
[[ "$platform" == imx93-tatsu ]] || die "target is not a Paper Pure"
[[ "$architecture" == aarch64 ]] || die "target architecture is not aarch64"
node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' \
  "$ROOT/config/compatibility.json" "$os_version" || die "OS $os_version is not approved"

"$ROOT/scripts/verify-appload-runtime.sh" --host "$host" --wait 0

remote_status="$(ssh "${ssh_options[@]}" "$host" sh <<'REMOTE'
set -eu
app_root=/home/root/xovi/exthome/appload
paperboard=$app_root/paperboard
paperterm=$app_root/paperterm
test -x "$paperboard/backend/entry"
test -s "$paperboard/manifest.json"
test -s "$paperboard/resources.rcc"
test -s "$paperboard/icon.png"
test -x "$paperterm/backend/entry"
test -s "$paperterm/manifest.json"
test -s "$paperterm/resources.rcc"
test -s "$paperterm/icon.png"
test -s "$paperterm/fonts/NotoMonoNerdFontMono-Regular.ttf"
paperterm_self_test=$($paperterm/backend/entry --self-test)
test "$paperterm_self_test" = "paperterm backend self-test: ok"
paperboard_release=$(cat /home/root/.local/share/paperboard/current-release)
paperterm_release=$(cat /home/root/.local/share/paperterm/current-release)
paperboard_actual=$({
  sha256sum "$paperboard/manifest.json" | cut -d' ' -f1
  sha256sum "$paperboard/resources.rcc" | cut -d' ' -f1
  sha256sum "$paperboard/backend/entry" | cut -d' ' -f1
  sha256sum "$paperboard/icon.png" | cut -d' ' -f1
} | sha256sum | cut -c1-16)
paperterm_actual=$({
  sha256sum "$paperterm/manifest.json" | cut -d' ' -f1
  sha256sum "$paperterm/resources.rcc" | cut -d' ' -f1
  sha256sum "$paperterm/backend/entry" | cut -d' ' -f1
  sha256sum "$paperterm/icon.png" | cut -d' ' -f1
  sha256sum "$paperterm/LICENSE.libvterm" | cut -d' ' -f1
  sha256sum "$paperterm/fonts/NotoMonoNerdFontMono-Regular.ttf" | cut -d' ' -f1
  sha256sum "$paperterm/LICENSE.nerd-fonts.txt" | cut -d' ' -f1
} | sha256sum | cut -c1-16)
test "$paperboard_release" = "$paperboard_actual"
test "$paperterm_release" = "$paperterm_actual"
paperboard_rollback=false
paperterm_rollback=false
test ! -d /home/root/.local/share/paperboard/deployment-previous || paperboard_rollback=true
test ! -d /home/root/.local/share/paperterm/deployment-previous || paperterm_rollback=true
printf '%s|%s|%s|%s|%s|%s|%s\n' \
  "$paperboard_release" "$paperterm_release" \
  "$(systemctl is-active xochitl)" "$(systemctl is-active dropbear-wlan.socket)" \
  "$paperboard_rollback" "$paperterm_rollback" "$paperterm_self_test"
REMOTE
)" || die "installed application integrity check failed"

IFS='|' read -r paperboard_release paperterm_release xochitl_service ssh_service \
  paperboard_rollback paperterm_rollback paperterm_self_test <<<"$remote_status"
[[ "$xochitl_service" == active ]] || die "xochitl is not active"
[[ "$ssh_service" == active ]] || die "Wi-Fi SSH socket is not active"

temporary_directory="$(mktemp -d)"
cleanup() { rm -rf "$temporary_directory"; }
trap cleanup EXIT INT TERM
scp "${ssh_options[@]}" "$host:/home/root/xovi/exthome/appload/paperboard/icon.png" \
  "$temporary_directory/paperboard.png" >/dev/null
scp "${ssh_options[@]}" "$host:/home/root/xovi/exthome/appload/paperterm/icon.png" \
  "$temporary_directory/paperterm.png" >/dev/null
node - "$temporary_directory/paperboard.png" "$temporary_directory/paperterm.png" <<'NODE'
const fs = require("fs");
for (const path of process.argv.slice(2)) {
  const bytes = fs.readFileSync(path);
  if (bytes.length < 24 || bytes.subarray(1, 4).toString() !== "PNG" ||
      bytes.readUInt32BE(16) !== 100 || bytes.readUInt32BE(20) !== 100) process.exit(1);
}
NODE

if $json; then
  node - "$os_version" "$paperboard_release" "$paperterm_release" "$xochitl_service" "$ssh_service" \
    "$paperboard_rollback" "$paperterm_rollback" <<'NODE'
const [os, paperboard, paperterm, xochitl, ssh, paperboardRollback, papertermRollback] = process.argv.slice(2);
console.log(JSON.stringify({
  ok: true,
  device: { model: "reMarkable Paper Pure", platform: "imx93-tatsu", architecture: "aarch64", os },
  services: { xochitl, wifi_ssh: ssh },
  applications: {
    paperboard: { release: paperboard, icon: "100x100 PNG", rollback_available: paperboardRollback === "true" },
    paperterm: { release: paperterm, icon: "100x100 PNG", backend_self_test: "ok", rollback_available: papertermRollback === "true" },
  },
}, null, 2));
NODE
else
  printf 'PASS  Paper Pure identity and approved OS %s\n' "$os_version"
  printf 'PASS  xochitl and Wi-Fi SSH services are active\n'
  printf 'PASS  Paperboard release %s matches installed content\n' "$paperboard_release"
  printf 'PASS  PaperTerm release %s matches installed content\n' "$paperterm_release"
  printf 'PASS  both AppLoad icons are 100x100 PNG files\n'
  printf 'PASS  %s\n' "$paperterm_self_test"
  printf 'INFO  rollback available: paperboard=%s paperterm=%s\n' "$paperboard_rollback" "$paperterm_rollback"
fi
