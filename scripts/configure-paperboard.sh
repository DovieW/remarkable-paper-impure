#!/usr/bin/env bash
set -euo pipefail

host=remarkable-usb
url_file=""
relay_config=""
remove=false
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Configure Paperboard's private on-device relay or legacy dashboard source.

Usage:
  configure-paperboard.sh [--host HOST] --from-file FILE [--dry-run]
  configure-paperboard.sh [--host HOST] --relay-config FILE [--dry-run]
  configure-paperboard.sh [--host HOST] --remove [--dry-run]

FILE must contain exactly one HTTPS URL on its first line. Keep signed or
credential-bearing URLs outside this repository. The URL is transferred over
SSH without being printed and stored root-only at:
  /home/root/.config/paperboard/config

A relay config is a private mode-0600 file containing:
  mode=relay
  relay_url=https://paperboard.example-tailnet.ts.net
  device_id=paper-pure
  device_token=pb_device_REDACTED
  proxy=socks5h://127.0.0.1:1055
  poll_wait=25
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --host)
      (( $# >= 2 )) || die "--host requires a value"
      host=$2
      shift 2
      ;;
    --from-file)
      (( $# >= 2 )) || die "--from-file requires a value"
      url_file=$2
      shift 2
      ;;
    --relay-config)
      (( $# >= 2 )) || die "--relay-config requires a value"
      relay_config=$2
      shift 2
      ;;
    --remove)
      remove=true
      shift
      ;;
    --dry-run)
      dry_run=true
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

if $remove; then
  [[ -z "$url_file" && -z "$relay_config" ]] || die "choose exactly one configuration action"
else
  [[ -n "$url_file" || -n "$relay_config" ]] || die "choose --from-file, --relay-config, or --remove"
  [[ -z "$url_file" || -z "$relay_config" ]] || die "choose exactly one configuration source"
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r device_hostname architecture image_version <<< "$identity"
[[ "$device_hostname" == imx93-tatsu ]] || die "unexpected device platform: $device_hostname"
[[ "$architecture" == aarch64 ]] || die "unexpected architecture: $architecture"
[[ "$image_version" == 3.27.* ]] || die "Paperboard is currently constrained to OS 3.27.x, found $image_version"

if [[ -n "$relay_config" ]]; then
  [[ -f "$relay_config" && ! -L "$relay_config" ]] || die "relay config must be a regular, non-symlink file"
  permissions=$(stat -c '%a' "$relay_config")
  (( (8#$permissions & 077) == 0 )) || die "relay config must not be readable by group or others"
  (( $(stat -c '%s' "$relay_config") <= 16384 )) || die "relay config is too large"
  mapfile -t config_lines < "$relay_config"
  declare -A seen=()
  for line in "${config_lines[@]}"; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "relay config contains a malformed line"
    key=${line%%=*}
    value=${line#*=}
    [[ -z "${seen[$key]:-}" ]] || die "relay config contains duplicate key: $key"
    seen[$key]=1
    case "$key" in
      mode) [[ "$value" == relay ]] || die "mode must be relay" ;;
      relay_url) [[ "$value" == https://* && "$value" != *'@'* ]] || die "relay_url must be HTTPS without user info" ;;
      device_id) [[ "$value" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "device_id is invalid" ;;
      device_token) (( ${#value} >= 32 )) || die "device_token is too short" ;;
      proxy) [[ "$value" == socks5h://127.0.0.1:* || "$value" == socks5h://\[::1\]:* ]] || die "proxy must be loopback SOCKS5" ;;
      poll_wait) [[ "$value" =~ ^[0-9]+$ ]] && (( value <= 25 )) || die "poll_wait must be 0-25" ;;
      *) die "relay config contains unknown key: $key" ;;
    esac
  done
  for required in mode relay_url device_id device_token; do [[ -n "${seen[$required]:-}" ]] || die "relay config is missing $required"; done
  if $dry_run; then
    printf 'Would install a redacted relay configuration on %s with mode 0600.\n' "$host"
    exit 0
  fi
  ssh "${ssh_options[@]}" "$host" 'set -eu
mkdir -p /home/root/.config/paperboard
chmod 700 /home/root/.config/paperboard
umask 077
temporary=/home/root/.config/paperboard/config.tmp.$$
trap '\''rm -f "$temporary"'\'' EXIT INT TERM
cat > "$temporary"
chmod 600 "$temporary"
mv "$temporary" /home/root/.config/paperboard/config
trap - EXIT INT TERM' < "$relay_config"
  printf 'Paperboard relay configuration installed on %s (credentials redacted).\n' "$host"
  exit 0
fi

if $remove; then
  if $dry_run; then
    printf 'Would remove Paperboard dashboard configuration from %s.\n' "$host"
  else
    ssh "${ssh_options[@]}" "$host" 'rm -f /home/root/.config/paperboard/config'
    printf 'Paperboard dashboard configuration removed from %s.\n' "$host"
  fi
  exit 0
fi

[[ -f "$url_file" && ! -L "$url_file" ]] || die "URL file must be a regular, non-symlink file"
mapfile -t url_lines < "$url_file"
(( ${#url_lines[@]} == 1 )) || die "URL file must contain exactly one line"
dashboard_url=${url_lines[0]}
[[ "$dashboard_url" == https://* ]] || die "URL must begin with https://"
[[ "$dashboard_url" != *$'\n'* && "$dashboard_url" != *$'\r'* ]] || die "URL contains a line break"
[[ "$dashboard_url" != *'@'* ]] || die "embedded URL user info is not allowed"
(( ${#dashboard_url} <= 4000 )) || die "URL is too long"

if $dry_run; then
  printf 'Would install a redacted HTTPS dashboard URL on %s with mode 0600.\n' "$host"
  exit 0
fi

printf 'url=%s\n' "$dashboard_url" | ssh "${ssh_options[@]}" "$host" 'set -eu
mkdir -p /home/root/.config/paperboard
chmod 700 /home/root/.config/paperboard
umask 077
temporary=/home/root/.config/paperboard/config.tmp.$$
trap '\''rm -f "$temporary"'\'' EXIT INT TERM
cat > "$temporary"
chmod 600 "$temporary"
mv "$temporary" /home/root/.config/paperboard/config
trap - EXIT INT TERM'
printf 'Paperboard dashboard configuration installed on %s (URL redacted).\n' "$host"
