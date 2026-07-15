#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"

usb_host="${REMARKABLE_USB_HOST:-10.11.99.1}"
key_file="${REMARKABLE_KEY_FILE:-$HOME/.ssh/remarkable_paper_pure_ed25519}"
config_dir="${REMARKABLE_SSH_CONFIG_DIR:-$HOME/.ssh/config.d}"
config_file="${REMARKABLE_SSH_CONFIG:-$HOME/.ssh/config}"
fragment_file=""
host_key_alias="remarkable-paper-pure"
enable_wifi=false
dry_run=false

usage() {
  cat <<'EOF'
Safely bootstrap public-key SSH to a reMarkable Paper Pure over physical USB.

Usage: bootstrap-ssh.sh [options]

Options:
  --usb-host ADDRESS  Tablet USB address (default: 10.11.99.1)
  --key FILE          Dedicated private-key path
  --enable-wifi       Enable SSH on the current trusted LAN and add aliases
  --dry-run           Validate the host and show planned actions; change nothing
  -h, --help          Show this help

The real run asks the owner to confirm the host key and enter the tablet's
generated root password directly in the local terminal. It never stores that
password.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --usb-host)
      (($# >= 2)) || die "--usb-host requires a value"
      usb_host="$2"
      shift 2
      ;;
    --key)
      (($# >= 2)) || die "--key requires a value"
      key_file="$2"
      shift 2
      ;;
    --enable-wifi)
      enable_wifi=true
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

for command_name in ssh ssh-keygen ssh-keyscan ssh-copy-id awk grep mktemp; do
  command -v "$command_name" >/dev/null \
    || die "required command not found: $command_name"
done

fragment_file="${config_dir%/}/remarkable-paper-pure.conf"

printf 'Planned dedicated key: %s\n' "$key_file"
printf 'Planned SSH fragment: %s\n' "$fragment_file"
printf 'Physical USB target: root@%s\n' "$usb_host"
printf 'Wi-Fi SSH requested: %s\n' "$enable_wifi"

if $dry_run; then
  printf 'Dry run complete: no key, config, network, or tablet state was changed.\n'
  exit 0
fi

if [[ -e "$key_file" && ! -f "$key_file.pub" ]]; then
  die "private key exists but public key is missing: $key_file.pub"
fi

umask 077
mkdir -p "$HOME/.ssh" "$config_dir"
chmod 700 "$HOME/.ssh" "$config_dir"

if [[ ! -f "$key_file" ]]; then
  printf '\nCreating a dedicated Ed25519 key.\n'
  printf 'Choose a passphrase when prompted, or press Enter only if unattended access is required.\n'
  ssh-keygen -t ed25519 -f "$key_file" \
    -C "${USER:-owner}@${HOSTNAME:-host}-remarkable-paper-pure"
fi
chmod 600 "$key_file"
chmod 644 "$key_file.pub"

if ! ssh-keyscan -T 10 "$usb_host" > "$(dirname "$key_file")/.remarkable-keyscan.$$" 2>/dev/null; then
  rm -f "$(dirname "$key_file")/.remarkable-keyscan.$$"
  die "SSH is not reachable at $usb_host. Unlock the tablet, connect a data-capable USB cable, and enable the USB web interface."
fi
scan_file="$(dirname "$key_file")/.remarkable-keyscan.$$"
trap 'rm -f "$scan_file"' EXIT INT TERM

printf '\nHost key presented over the physical USB connection:\n'
ssh-keygen -lf "$scan_file"
printf '\nConfirm only if the expected tablet is physically connected.\n'
read -r -p 'Trust and pin this tablet host key? [y/N] ' answer
[[ "$answer" == y || "$answer" == Y ]] || die "host key was not trusted"

cat > "$fragment_file" <<EOF
Host remarkable-usb
    HostName $usb_host
    User root
    IdentityFile $key_file
    IdentitiesOnly yes
    HostKeyAlias $host_key_alias
    StrictHostKeyChecking yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ConnectTimeout 10
EOF
chmod 600 "$fragment_file"

include_line="Include ${config_dir%/}/*"
if [[ ! -f "$config_file" ]]; then
  printf '%s\n' "$include_line" > "$config_file"
elif ! grep -Fqx "$include_line" "$config_file"; then
  temp_config="$(mktemp "${config_file}.XXXXXX")"
  {
    printf '%s\n\n' "$include_line"
    cat "$config_file"
  } > "$temp_config"
  chmod 600 "$temp_config"
  mv "$temp_config" "$config_file"
fi
chmod 600 "$config_file"

# Pin the key under a stable alias so USB and Wi-Fi must present one identity.
ssh-keygen -R "$host_key_alias" >/dev/null 2>&1 || true
awk -v alias="$host_key_alias" '{print alias, $2, $3}' "$scan_file" \
  >> "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/known_hosts"

printf '\nInstalling the public key. Enter the generated tablet password locally.\n'
printf 'The password will not be stored by this script.\n'
ssh-copy-id -i "$key_file.pub" \
  -o HostKeyAlias="$host_key_alias" \
  -o StrictHostKeyChecking=yes \
  "root@$usb_host"

ssh -o BatchMode=yes remarkable-usb 'test "$(id -u)" = 0' \
  || die "key-authenticated root SSH verification failed"

identity="$(ssh -o BatchMode=yes remarkable-usb \
  'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release')"
IFS='|' read -r device_hostname architecture image_version <<< "$identity"

printf '\nConnected device:\n'
printf '  platform: %s\n  architecture: %s\n  OS image: %s\n' \
  "$device_hostname" "$architecture" "$image_version"

[[ "$device_hostname" == "imx93-tatsu" ]] \
  || die "unexpected platform '$device_hostname'; stop before device changes"
[[ "$architecture" == "aarch64" ]] \
  || die "unexpected architecture '$architecture'; stop before device changes"

if $enable_wifi; then
  printf '\nEnabling SSH over the tablet current Wi-Fi connection...\n'
  ssh remarkable-usb rm-ssh-over-wlan on
  wifi_address="$(ssh remarkable-usb \
    'ip -4 -o address show dev wlan0 | awk '\''{print $4}'\'' | cut -d/ -f1 | head -n1')"
  [[ -n "$wifi_address" ]] || die "Wi-Fi SSH was enabled, but wlan0 has no IPv4 address"

  cat >> "$fragment_file" <<EOF

Host remarkable-wifi remarkable
    HostName $wifi_address
    User root
    IdentityFile $key_file
    IdentitiesOnly yes
    HostKeyAlias $host_key_alias
    StrictHostKeyChecking yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ConnectTimeout 10
EOF
  chmod 600 "$fragment_file"
  ssh -o BatchMode=yes remarkable 'true' \
    || die "Wi-Fi key-authentication verification failed; USB access remains available"
  printf 'Wi-Fi SSH verified. Its address is stored only in your local SSH config.\n'
fi

printf '\nBootstrap complete. Next commands:\n'
printf '  scripts/status.sh --host remarkable-usb\n'
printf '  scripts/backup.sh --host remarkable-usb --dry-run\n'
printf '  scripts/backup.sh --host remarkable-usb\n'
