#!/usr/bin/env bash
set -Eeuo pipefail
readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; readonly ROOT
sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
build_directory="${CHAT_BUILD_DIR:-$ROOT/build/chat-tatsu}"
clean=false
die(){ printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
while (($#)); do case "$1" in --sdk-root) sdk_root="$2";shift 2;;--clean)clean=true;shift;;-h|--help)printf 'Usage: build-chat.sh [--sdk-root DIRECTORY] [--clean]\n';exit 0;;*)die "unknown argument: $1";;esac;done
mapfile -t environments < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#environments[@]} == 1 )) || die "expected one SDK environment file under $sdk_root"
command -v rsvg-convert >/dev/null || die "rsvg-convert is required"
$clean && rm -rf "$build_directory"
export LANG=C.utf8 LC_ALL=C.utf8
# shellcheck disable=SC1090
source "${environments[0]}"
mkdir -p "$build_directory/backend"
(cd "$ROOT/src/chat" && "$OECORE_NATIVE_SYSROOT/usr/libexec/rcc" --binary -o "$build_directory/resources.rcc" application.qrc)
install -m 0644 "$ROOT/src/chat/packaging/manifest.json" "$build_directory/manifest.json"
rsvg-convert --width 100 --height 100 --output "$build_directory/icon.png" "$ROOT/src/chat/packaging/icon.svg"
read -r -a compiler <<< "$CC"; read -r -a json_c_cflags <<< "$(pkg-config --cflags json-c)"
"${compiler[@]}" -std=c11 -Os -Wall -Wextra -Werror "${json_c_cflags[@]}" "$ROOT/src/chat/backend/chat-backend.c" -lcurl -lpthread -o "$build_directory/backend/entry"
[[ -s "$build_directory/resources.rcc" && -x "$build_directory/backend/entry" && -s "$build_directory/icon.png" ]] || die "Chat bundle is incomplete"
printf 'Chat AppLoad bundle complete: %s\n' "$build_directory"
