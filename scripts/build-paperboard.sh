#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
build_directory="${PAPERBOARD_BUILD_DIR:-$REPOSITORY_ROOT/build/paperboard-tatsu}"
clean=false

usage() {
  cat <<'EOF'
Build the Paperboard AppLoad QML resource bundle.

Usage: build-paperboard.sh [--sdk-root DIRECTORY] [--clean]
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --sdk-root)
      (($# >= 2)) || die "--sdk-root requires a value"
      sdk_root="$2"
      shift 2
      ;;
    --clean)
      clean=true
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

mapfile -t environment_files < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#environment_files[@]} == 1 )) \
  || die "expected one SDK environment file under $sdk_root; run scripts/setup-paperboard-sdk.sh"

if $clean; then
  rm -rf "$build_directory"
fi

# The official SDK provides the Qt resource compiler matching the tablet.
# shellcheck disable=SC1090
source "${environment_files[0]}"
export LANG=C.utf8
export LC_ALL=C.utf8

rcc_binary="$OECORE_NATIVE_SYSROOT/usr/libexec/rcc"
[[ -x "$rcc_binary" ]] || die "Qt resource compiler not found after SDK activation"

mkdir -p "$build_directory"
(
  cd "$REPOSITORY_ROOT/src/paperboard"
  "$rcc_binary" --binary -o "$build_directory/resources.rcc" application.qrc
)
cp "$REPOSITORY_ROOT/src/paperboard/packaging/manifest.json" \
  "$build_directory/manifest.json"
mkdir -p "$build_directory/backend"
read -r -a compiler <<< "$CC"
"${compiler[@]}" \
  -std=c11 -Os -Wall -Wextra -Werror \
  "$REPOSITORY_ROOT/src/paperboard/backend/paperboard-backend.c" \
  -lcurl \
  -o "$build_directory/backend/entry"

[[ -s "$build_directory/resources.rcc" ]] || die "resource bundle was not created"
[[ -x "$build_directory/backend/entry" ]] || die "backend was not created"
printf 'Paperboard AppLoad bundle complete: %s\n' "$build_directory"
ls -l "$build_directory/manifest.json" "$build_directory/resources.rcc" \
  "$build_directory/backend/entry"
