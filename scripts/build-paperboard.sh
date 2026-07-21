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

filter_qt_locale_warning() {
  sed '/^Detected locale "C" with character encoding "ANSI_X3.4-1968"/,/^for more information\.$/d' >&2
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
rsvg_binary="$(command -v rsvg-convert)" || die "rsvg-convert is required to render the AppLoad icon"
export LANG=C.utf8
export LC_ALL=C.utf8

if $clean; then
  rm -rf "$build_directory"
fi

# The official SDK provides the Qt resource compiler matching the tablet.
# shellcheck disable=SC1090
source "${environment_files[0]}"

rcc_binary="$OECORE_NATIVE_SYSROOT/usr/libexec/rcc"
[[ -x "$rcc_binary" ]] || die "Qt resource compiler not found after SDK activation"

mkdir -p "$build_directory"
(
  cd "$REPOSITORY_ROOT/src/paperboard"
  "$rcc_binary" --binary -o "$build_directory/resources.rcc" application.qrc \
    2> >(filter_qt_locale_warning)
)
cp "$REPOSITORY_ROOT/src/paperboard/packaging/manifest.json" \
  "$build_directory/manifest.json"
"$rsvg_binary" --width 100 --height 100 \
  --output "$build_directory/icon.png" \
  "$REPOSITORY_ROOT/src/paperboard/packaging/icon.svg"
mkdir -p "$build_directory/backend"
read -r -a compiler <<< "$CC"
read -r -a json_c_cflags <<< "$(pkg-config --cflags json-c)"
"${compiler[@]}" \
  -std=c11 -Os -Wall -Wextra -Werror \
  "${json_c_cflags[@]}" \
  "$REPOSITORY_ROOT/src/paperboard/backend/paperboard-backend.c" \
  -lcurl -ljson-c -lpthread \
  -o "$build_directory/backend/entry"

[[ -s "$build_directory/resources.rcc" ]] || die "resource bundle was not created"
[[ -x "$build_directory/backend/entry" ]] || die "backend was not created"
[[ -s "$build_directory/icon.png" ]] || die "AppLoad icon was not created"
printf 'Paperboard AppLoad bundle complete: %s\n' "$build_directory"
ls -l "$build_directory/icon.png" "$build_directory/manifest.json" "$build_directory/resources.rcc" \
  "$build_directory/backend/entry"
