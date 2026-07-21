#!/usr/bin/env bash
set -Eeuo pipefail

host="${REMARKABLE_HOST:-remarkable-usb}"
dry_run=false
public_key_file=""
usage() {
  cat <<'EOF'
Install the forced-command Paperboard control boundary on a Paper Pure.

Usage:
  install-paperboard-tablet-control.sh --public-key FILE [--host ALIAS] [--dry-run]

The key can enumerate AppLoad manifests, report state, capture an ephemeral
screenshot, and open the reviewed bounded tap/swipe protocol. Launch remains
fail-closed until a reviewed local AppLoad launch helper is installed. The
forced command never accepts shell text, paths, text input, or passcodes.
EOF
}
while (($#)); do
  case "$1" in
    --public-key) public_key_file=${2:?}; shift 2 ;;
    --host) host=${2:?}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -f $public_key_file ]] || { echo "--public-key FILE is required" >&2; exit 2; }
key=$(<"$public_key_file")
[[ $key == ssh-ed25519\ * ]] || { echo "only an Ed25519 public key is accepted" >&2; exit 1; }
ssh -o BatchMode=yes "$host" 'test "$(hostname)" = imx93-tatsu && test "$(uname -m)" = aarch64 && test -d /home/root/xovi/exthome/appload'
$dry_run && { echo "Paperboard tablet-control install dry run passed."; exit 0; }

remote_script=$(mktemp)
trap 'rm -f "$remote_script"' EXIT
sed -n '/^__REMOTE__$/,$p' "$0" | sed '1d' >"$remote_script"
remote_key="/home/root/.local/share/paperboard-control/authorized-key.install.$$.$RANDOM"
ssh -o BatchMode=yes "$host" 'mkdir -p /home/root/.local/share/paperboard-control && chmod 0700 /home/root/.local/share/paperboard-control'
scp -q "$remote_script" "$host:/home/root/.local/bin/paperboard-control"
scp -q "$public_key_file" "$host:$remote_key"
ssh -o BatchMode=yes "$host" sh -s -- "$remote_key" <<'REMOTE'
set -eu
key_file=$1
trap 'rm -f "$key_file"' EXIT INT TERM
key=$(cat "$key_file")
case "$key" in ssh-ed25519\ *) ;; *) echo "invalid staged public key" >&2; exit 1;; esac
chmod 0700 /home/root/.local/bin/paperboard-control
mkdir -p /home/root/.ssh /home/root/.local/share/paperboard-control
chmod 0700 /home/root/.ssh
test -f /home/root/.ssh/authorized_keys && cp /home/root/.ssh/authorized_keys /home/root/.local/share/paperboard-control/authorized_keys.before || true
line="restrict,command=\"/home/root/.local/bin/paperboard-control\" $key"
grep -Fqx "$line" /home/root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$line" >>/home/root/.ssh/authorized_keys
chmod 0600 /home/root/.ssh/authorized_keys
REMOTE
echo "Forced-command Paperboard tablet control installed."
exit 0

__REMOTE__
#!/bin/sh
set -eu
command=${SSH_ORIGINAL_COMMAND:-}
set -- $command
test "${1:-}" = paperboard-control || { echo '{"error":"invalid command"}'; exit 1; }
action=${2:-}; argument=${3:-}; test -z "${4:-}" || exit 2
case "$action" in
  status)
    foreground=stock
    ps | grep -F 'backend/entry /tmp/paperboard.sock' | grep -v grep >/dev/null && foreground=paperboard
    ps | grep -F 'backend/entry /tmp/canvas.sock' | grep -v grep >/dev/null && foreground=canvas
    ps | grep -F 'backend/entry /tmp/paperterm.sock' | grep -v grep >/dev/null && foreground=paperterm
    printf '{"platform":"%s","architecture":"%s","foreground":"%s","launch_available":%s,"screenshot_available":%s}\n' \
      "$(hostname)" "$(uname -m)" "$foreground" \
      "$(test -d /run/paperboard-appload && echo true || echo false)" \
      "$(test -p /run/xovi-mb && echo true || echo false)"
    ;;
  apps)
    printf '{"apps":['; first=true
    for manifest in /home/root/xovi/exthome/appload/*/manifest.json; do
      test -f "$manifest" || continue
      id=${manifest%/manifest.json}; id=${id##*/}
      $first || printf ','; first=false
      printf '"%s"' "$id"
    done
    printf ']}\n'
    ;;
  launch)
    case "$argument" in ''|*[!A-Za-z0-9._:-]*) echo '{"error":"invalid app id"}'; exit 1;; esac
    test "$argument" != paperterm || { echo '{"error":"PaperTerm must be launched physically on the tablet"}'; exit 1; }
    test -f "/home/root/xovi/exthome/appload/$argument/manifest.json" || test -f "/home/root/xovi/exthome/appload/${argument#external::}/external.manifest.json" || { echo '{"error":"app is not installed"}'; exit 1; }
    request_dir=/run/paperboard-appload
    test -d "$request_dir" || { echo '{"error":"reviewed AppLoad control adapter is not active"}'; exit 1; }
    test "$(stat -c %a "$request_dir")" = 700 || { echo '{"error":"unsafe AppLoad request directory mode"}'; exit 1; }
    tmp="$request_dir/.launch.$$"
    umask 077
    printf '%s\n' "$argument" >"$tmp"
    mv "$tmp" "$request_dir/launch"
    printf '{"queued":true,"app":"%s"}\n' "$argument"
    ;;
  return)
    for socket in paperboard canvas paperterm; do
      ps | awk -v target="backend/entry /tmp/$socket.sock" 'index($0, target) { print $1 }' \
        | while IFS= read -r pid; do
            case "$pid" in ''|*[!0-9]*) continue;; esac
            kill "$pid" 2>/dev/null || true
          done
    done
    echo '{"returned":true}'
    ;;
  screenshot)
    test -p /run/xovi-mb || exit 1
    output=/home/root/.local/share/paperboard-control/screenshot-$$.png
    trap 'rm -f "$output"' EXIT INT TERM
    rm -f "$output"
    echo ">etakeScreenshot:$output,0" >/run/xovi-mb
    test "$(cat /run/xovi-mb-out)" = success
    tries=0
    while test ! -s "$output"; do tries=$((tries + 1)); test "$tries" -lt 6 || exit 1; sleep 1; done
    cat "$output"
    ;;
  input)
    test -z "$argument" || exit 2
    ps | grep -F 'backend/entry /tmp/paperterm.sock' | grep -v grep >/dev/null \
      && { echo '{"error":"remote input is disabled while PaperTerm is open"}'; exit 1; }
    test -x /home/root/.local/bin/paperctl-tap || { echo '{"error":"input helper unavailable"}'; exit 1; }
    exec /home/root/.local/bin/paperctl-tap --serve
    ;;
  *) echo '{"error":"unsupported action"}'; exit 2 ;;
esac
