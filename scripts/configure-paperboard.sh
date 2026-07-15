#!/usr/bin/env bash
set -euo pipefail

host=remarkable-usb
url_file=""
remove=false
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Configure Paperboard's private on-device dashboard URL.

Usage:
  configure-paperboard.sh [--host HOST] --from-file FILE [--dry-run]
  configure-paperboard.sh [--host HOST] --remove [--dry-run]

FILE must contain exactly one HTTPS URL on its first line. Keep signed or
credential-bearing URLs outside this repository. The URL is transferred over
SSH without being printed and stored root-only at:
  /home/root/.config/paperboard/config
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
  [[ -z "$url_file" ]] || die "choose exactly one of --from-file or --remove"
else
  [[ -n "$url_file" ]] || die "choose exactly one of --from-file or --remove"
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
identity="$(ssh "${ssh_options[@]}" "$host" \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r device_hostname architecture image_version <<< "$identity"
[[ "$device_hostname" == imx93-tatsu ]] || die "unexpected device platform: $device_hostname"
[[ "$architecture" == aarch64 ]] || die "unexpected architecture: $architecture"
[[ "$image_version" == 3.27.* ]] || die "Paperboard is currently constrained to OS 3.27.x, found $image_version"

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
