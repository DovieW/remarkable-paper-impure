#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"

host="${REMARKABLE_HOST:-remarkable}"
destination_root="${REMARKABLE_BACKUP_DIR:-$HOME/remarkable-backups}"
include_sensitive_config=false
dry_run=false

usage() {
  cat <<'EOF'
Create a local, read-only backup of a reMarkable tablet.

Usage: backup.sh [options]

Options:
  --host HOST                  SSH host or alias (default: remarkable)
  --destination DIRECTORY     Backup parent directory
                              (default: ~/remarkable-backups)
  --include-sensitive-config  Include xochitl.conf in plaintext. This file may
                              contain the generated root password. Use only on
                              encrypted storage.
  --dry-run                    Verify access and print the planned destination
  -h, --help                   Show this help
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
    --destination)
      (($# >= 2)) || die "--destination requires a value"
      destination_root="$2"
      shift 2
      ;;
    --include-sensitive-config)
      include_sensitive_config=true
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

for command_name in ssh tar gzip sha256sum mktemp; do
  command -v "$command_name" >/dev/null || die "required command not found: $command_name"
done

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)

ssh "${ssh_options[@]}" "$host" 'test "$(id -u)" = 0' \
  || die "key-authenticated root SSH failed for $host"

image_version="$({
  ssh "${ssh_options[@]}" "$host" \
    'sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release'
} | tr -d '\r\n')"
[[ -n "$image_version" ]] || die "could not determine the device OS image version"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="paper-pure-${image_version}-${timestamp}"
final_directory="${destination_root%/}/$backup_name"

if $dry_run; then
  printf 'SSH verification: OK\n'
  printf 'Device OS image: %s\n' "$image_version"
  printf 'Planned backup: %s\n' "$final_directory"
  printf 'Sensitive configuration: %s\n' "$include_sensitive_config"
  exit 0
fi

umask 077
mkdir -p "$destination_root"
staging_directory="$(mktemp -d "${destination_root%/}/.${backup_name}.partial.XXXXXX")"

cleanup() {
  if [[ -n "${staging_directory:-}" && -d "$staging_directory" ]]; then
    rm -rf "$staging_directory"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$staging_directory/metadata" "$staging_directory/access"

printf 'Capturing device metadata...\n'
ssh "${ssh_options[@]}" "$host" '
  printf "%s\n" "[time]"
  date -u
  printf "%s\n" "[identity]"
  hostname
  uname -a
  printf "%s\n" "[os-release]"
  cat /etc/os-release
  printf "%s\n" "[filesystems]"
  df -h
  printf "%s\n" "[mounts]"
  mount
  printf "%s\n" "[services]"
  for service in xochitl dropbear-wlan.socket; do
    printf "%s=" "$service"
    systemctl is-active "$service" 2>/dev/null || true
  done
  printf "%s\n" "[third-party-paths]"
  for path in \
    /home/root/.entware \
    /home/root/.local/share/vellum \
    /home/root/.config/vellum \
    /opt/vellum \
    /home/root/xovi \
    /home/root/koreader; do
    test -e "$path" && ls -ld "$path"
  done
  printf "%s\n" "[vellum-packages]"
  if test -x /home/root/.vellum/bin/vellum; then
    /home/root/.vellum/bin/vellum list --installed 2>/dev/null || true
  fi
  printf "%s\n" "[appload-manifests]"
  if test -d /home/root/xovi/exthome/appload; then
    find /home/root/xovi/exthome/appload \
      \( -name manifest.json -o -name external.manifest.json \) -print
  fi
  true
' > "$staging_directory/metadata/device.txt"

printf 'Capturing authorized public keys...\n'
ssh "${ssh_options[@]}" "$host" \
  'test ! -f /home/root/.ssh/authorized_keys || cat /home/root/.ssh/authorized_keys' \
  > "$staging_directory/access/authorized_keys"

printf 'Streaming document data...\n'
ssh "${ssh_options[@]}" "$host" \
  'tar -C /home/root/.local/share/remarkable -cf - xochitl' \
  | gzip -9 > "$staging_directory/documents-xochitl.tar.gz"

tar -tzf "$staging_directory/documents-xochitl.tar.gz" >/dev/null \
  || die "document archive verification failed"

if $include_sensitive_config; then
  printf '%s\n' \
    'WARNING: copying xochitl.conf, which may contain the root password in plaintext.' >&2
  mkdir -p "$staging_directory/sensitive"
  ssh "${ssh_options[@]}" "$host" \
    'cat /home/root/.config/remarkable/xochitl.conf' \
    > "$staging_directory/sensitive/xochitl.conf"
  chmod 600 "$staging_directory/sensitive/xochitl.conf"
else
  cat > "$staging_directory/SENSITIVE-CONFIG-NOT-INCLUDED.txt" <<'EOF'
xochitl.conf was deliberately excluded because it may contain the generated
root password in plaintext. Re-run with --include-sensitive-config only when
the destination is encrypted and access controlled.
EOF
fi

cat > "$staging_directory/README.txt" <<EOF
reMarkable Paper Pure backup
Created (UTC): $timestamp
Source SSH alias: $host
OS image: $image_version
Snapshot type: live, read-only user-data copy
Sensitive xochitl.conf included: $include_sensitive_config

The stock UI remained running while this archive was created. This follows the
community guide's copy-based approach and avoids interrupting normal service,
but it is not a block-level disk image.
EOF

(
  cd "$staging_directory"
  manifest="$(mktemp .SHA256SUMS.XXXXXX)"
  find . -type f ! -name '.SHA256SUMS.*' -print0 \
    | sort -z \
    | xargs -0 sha256sum > "$manifest"
  mv "$manifest" SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)

chmod -R go-rwx "$staging_directory"
mv "$staging_directory" "$final_directory"
staging_directory=""
trap - EXIT INT TERM

printf 'Backup complete: %s\n' "$final_directory"
printf 'Verify with: (cd %q && sha256sum -c SHA256SUMS)\n' "$final_directory"
