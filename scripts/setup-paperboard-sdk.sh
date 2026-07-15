#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SDK_VERSION="3.27.0.97"
readonly SDK_PLATFORM="tatsu"
readonly SDK_FILENAME="remarkable-production-image-5.7.119-tatsu-public-x86_64-toolchain.sh"
readonly SDK_SHA256="165d9f090a8bece2e8df695adb606cd7146c1b76699be3d530c0f23105264dd5"
readonly SDK_URL="https://storage.googleapis.com/remarkable-codex-toolchain/$SDK_VERSION/$SDK_PLATFORM/$SDK_FILENAME"

destination="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
cache_directory="${XDG_CACHE_HOME:-$HOME/.cache}/remarkable-sdk"
dry_run=false

usage() {
  cat <<'EOF'
Download, verify, and install the official Paper Pure 3.27 SDK.

Usage: setup-paperboard-sdk.sh [--destination DIRECTORY] [--dry-run]

The SDK is installed outside the Git repository. The installer is about
484 MB, and the installed toolchain requires additional disk space.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --destination)
      (($# >= 2)) || die "--destination requires a value"
      destination="$2"
      shift 2
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

for command_name in curl sha256sum find grep; do
  command -v "$command_name" >/dev/null \
    || die "required command not found: $command_name"
done

printf 'Official SDK URL: %s\n' "$SDK_URL"
printf 'Expected SHA-256: %s\n' "$SDK_SHA256"
printf 'Install destination: %s\n' "$destination"

if $dry_run; then
  printf 'Dry run complete: no download or installation was performed.\n'
  exit 0
fi

if find "$destination" -maxdepth 1 -type f -name 'environment-setup-*' \
    -print -quit 2>/dev/null | grep -q .; then
  printf 'SDK already installed: %s\n' "$destination"
  exit 0
fi

mkdir -p "$cache_directory" "$(dirname "$destination")"
installer="$cache_directory/$SDK_FILENAME"

curl --fail --location --retry 3 --continue-at - \
  --output "$installer" "$SDK_URL"
printf '%s  %s\n' "$SDK_SHA256" "$installer" | sha256sum -c -
chmod 700 "$installer"

[[ ! -e "$destination" ]] \
  || die "destination exists but does not contain a complete SDK: $destination"

"$installer" -y -d "$destination"

environment_file="$(find "$destination" -maxdepth 1 -type f \
  -name 'environment-setup-*' -print -quit)"
[[ -n "$environment_file" ]] || die "SDK installer completed without an environment file"
printf 'Paper Pure SDK installed: %s\n' "$destination"
printf 'Environment: %s\n' "$environment_file"
