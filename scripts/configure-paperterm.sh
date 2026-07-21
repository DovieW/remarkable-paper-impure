#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

host="${REMARKABLE_HOST:-remarkable-usb}"
config_file=""
dry_run=false
generate_key=false
public_key_output=""
known_host_name=""
known_host_public_key=""

usage() {
  cat <<'EOF'
Install a private PaperTerm profile file and optionally create its SSH key.

Usage: configure-paperterm.sh --config FILE [--host HOST] [--generate-key --public-key-output FILE]
       [--known-host-name NAME --known-host-public-key FILE] [--dry-run]

The public-key output must be outside this repository. The private key never
leaves the tablet. Existing keys are never overwritten.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host="$2"; shift 2 ;;
    --config) (($# >= 2)) || die "--config requires a value"; config_file="$2"; shift 2 ;;
    --generate-key) generate_key=true; shift ;;
    --public-key-output) (($# >= 2)) || die "--public-key-output requires a value"; public_key_output="$2"; shift 2 ;;
    --known-host-name) (($# >= 2)) || die "--known-host-name requires a value"; known_host_name="$2"; shift 2 ;;
    --known-host-public-key) (($# >= 2)) || die "--known-host-public-key requires a value"; known_host_public_key="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n "$known_host_name" || -n "$known_host_public_key" ]]; then
  [[ "$known_host_name" =~ ^[A-Za-z0-9_.:-]{1,255}$ ]] || die "known-host name is invalid"
  [[ -f "$known_host_public_key" ]] || die "known-host public-key file is missing"
  awk 'NF { count++; if ($1 != "ssh-ed25519" || $2 !~ /^[A-Za-z0-9+\/=]+$/) exit 1 } END { exit count == 1 ? 0 : 1 }' \
    "$known_host_public_key" || die "known-host key must contain exactly one Ed25519 public key"
fi

[[ -n "$config_file" && -f "$config_file" ]] || die "--config must name an existing file"
node - "$config_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!value || typeof value !== 'object' || !Array.isArray(value.profiles) || value.profiles.length > 32) process.exit(1);
for (const p of value.profiles) {
  if (!/^[A-Za-z0-9_.-]{1,64}$/.test(p.id || '') || typeof p.label !== 'string' || p.label.length < 1 || p.label.length > 96) process.exit(1);
  if (!['tailscale-ssh', 'tailscale-key', 'ssh', 'local'].includes(p.mode)) process.exit(1);
  if (p.mode === 'local' && value.allow_local_shell !== true) process.exit(1);
  if (p.mode !== 'local' && (!/^[A-Za-z0-9_.-]{1,64}$/.test(p.user || '') || !/^[A-Za-z0-9_.:-]{1,255}$/.test(p.host || ''))) process.exit(1);
  if (p.session !== undefined && p.session !== 'windows-powershell') process.exit(1);
  if (p.session === 'windows-powershell' && !['tailscale-ssh', 'tailscale-key'].includes(p.mode)) process.exit(1);
  if (['ssh', 'tailscale-key'].includes(p.mode) && (typeof p.identity_file !== 'string' || !p.identity_file.startsWith('/') || p.identity_file.includes('..'))) process.exit(1);
}
NODE

if $generate_key; then
  [[ -n "$public_key_output" ]] || die "--generate-key requires --public-key-output"
  case "$(realpath -m "$public_key_output")" in
    "$REPOSITORY_ROOT"/*) die "public-key output must be outside the repository" ;;
  esac
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" 'printf "%s|%s" "$(hostname)" "$(uname -m)"')"
[[ "$identity" == "imx93-tatsu|aarch64" ]] || die "target is not a Paper Pure"

if $dry_run; then
  printf 'PaperTerm profile validation passed; no tablet files were changed.\n'
  $generate_key && printf 'A dedicated tablet key would be created without exporting its private material.\n'
  [[ -n "$known_host_name" ]] && printf 'The supplied destination host key would be pinned for strict checking.\n'
  exit 0
fi

remote_stage="/home/root/.paperterm-config.$$"
remote_host_key_stage="/home/root/.paperterm-host-key.$$"
scp "${ssh_options[@]}" "$config_file" "$host:$remote_stage"
if [[ -n "$known_host_name" ]]; then
  scp "${ssh_options[@]}" "$known_host_public_key" "$host:$remote_host_key_stage"
fi
ssh "${ssh_options[@]}" "$host" sh -s -- "$remote_stage" "$generate_key" "$known_host_name" "$remote_host_key_stage" <<'REMOTE'
set -eu
stage=$1
generate_key=$2
known_host_name=$3
known_host_key_stage=$4
trap 'rm -f -- "$stage" "$known_host_key_stage"' EXIT
test "$(hostname)" = imx93-tatsu
test "$(uname -m)" = aarch64
mkdir -p /home/root/.config/paperterm /home/root/.ssh
chmod 700 /home/root/.config/paperterm /home/root/.ssh
if test -f /home/root/.config/paperterm/profiles.json; then
  cp -p /home/root/.config/paperterm/profiles.json /home/root/.config/paperterm/profiles.previous.json
fi
cp "$stage" /home/root/.config/paperterm/profiles.json
chmod 600 /home/root/.config/paperterm/profiles.json
tailscale_known_hosts=/home/root/.config/tailscale/ssh_known_hosts
if test -f "$tailscale_known_hosts" && test ! -L "$tailscale_known_hosts"; then
  known_hosts_stage=/home/root/.ssh/known_hosts.paperterm-new
  { test ! -f /home/root/.ssh/known_hosts || cat /home/root/.ssh/known_hosts; cat "$tailscale_known_hosts"; } \
    | sort -u > "$known_hosts_stage"
  chmod 600 "$known_hosts_stage"
  mv "$known_hosts_stage" /home/root/.ssh/known_hosts
fi
if test -n "$known_host_name"; then
  key_type=$(awk 'NF { print $1 }' "$known_host_key_stage")
  key_data=$(awk 'NF { print $2 }' "$known_host_key_stage")
  test "$key_type" = ssh-ed25519
  case "$key_data" in *[!A-Za-z0-9+/=]*|'') exit 1;; esac
  known_host_line="$known_host_name $key_type $key_data"
  grep -Fqx "$known_host_line" /home/root/.ssh/known_hosts 2>/dev/null \
    || printf '%s\n' "$known_host_line" >> /home/root/.ssh/known_hosts
  chmod 600 /home/root/.ssh/known_hosts
fi
if test "$generate_key" = true; then
  test ! -e /home/root/.ssh/paperterm_ed25519 || { echo 'PaperTerm key already exists; refusing to overwrite it.' >&2; exit 1; }
  dropbearkey -t ed25519 -f /home/root/.ssh/paperterm_ed25519 >/dev/null
  chmod 600 /home/root/.ssh/paperterm_ed25519
fi
REMOTE

if $generate_key; then
  umask 077
  ssh "${ssh_options[@]}" "$host" "dropbearkey -y -f /home/root/.ssh/paperterm_ed25519 | sed -n 's/^ssh-/ssh-/p'" > "$public_key_output"
  chmod 600 "$public_key_output"
  [[ -s "$public_key_output" ]] || die "public key export failed"
  printf 'Dedicated public key written to the requested path outside the repository.\n'
fi
printf 'PaperTerm profiles installed with mode 0600. Exit and reopen PaperTerm to reload them.\n'
