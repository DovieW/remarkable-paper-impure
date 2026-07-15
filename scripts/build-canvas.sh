#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
build="${CANVAS_BUILD_DIR:-$root/build/canvas-tatsu}"
[[ ${1:-} != --clean ]] || rm -rf "$build"
mapfile -t envs < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#envs[@]} == 1 )) || { echo "Canvas SDK environment not found" >&2; exit 1; }
# shellcheck disable=SC1090
source "${envs[0]}"
export LANG=C.utf8 LC_ALL=C.utf8
mkdir -p "$build/backend"
(cd "$root/src/canvas" && "$OECORE_NATIVE_SYSROOT/usr/libexec/rcc" --binary -o "$build/resources.rcc" application.qrc)
cp "$root/src/canvas/packaging/manifest.json" "$build/manifest.json"
read -r -a compiler <<< "$CC"
read -r -a json_flags <<< "$(pkg-config --cflags json-c)"
"${compiler[@]}" -DCANVAS_MODE -std=c11 -Os -Wall -Wextra -Werror "${json_flags[@]}" "$root/src/paperboard/backend/paperboard-backend.c" -lcurl -ljson-c -lpthread -o "$build/backend/entry"
printf 'Canvas AppLoad bundle complete: %s\n' "$build"
