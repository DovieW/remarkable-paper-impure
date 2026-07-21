#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
readonly LIBVTERM_REPOSITORY="https://github.com/neovim/libvterm.git"
readonly LIBVTERM_COMMIT="9d6d2112335080312ef8c36667fa717ded4f7daf"
readonly NERD_FONTS_VERSION="v3.4.0"
readonly NERD_FONTS_ARCHIVE_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/$NERD_FONTS_VERSION/Noto.tar.xz"
readonly NERD_FONTS_ARCHIVE_SHA256="e28b31609d17fc50bdf9e6730c947a61b0e474af726c2c044c39bc78fcd9bfde"
readonly NERD_FONT_FILE="NotoMonoNerdFontMono-Regular.ttf"
readonly NERD_FONT_SHA256="7ed8e51bbbc902f537541916f9443630e7781845985f1fbde36aa2db6a4b1c65"

sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
build_directory="${PAPERTERM_BUILD_DIR:-$REPOSITORY_ROOT/build/paperterm-tatsu}"
dependency_directory="${PAPERTERM_DEPS_DIR:-$REPOSITORY_ROOT/build/paperterm-deps/libvterm}"
font_dependency_directory="${PAPERTERM_FONT_DEPS_DIR:-$REPOSITORY_ROOT/build/paperterm-deps/nerd-fonts-$NERD_FONTS_VERSION}"
clean=false

usage() {
  cat <<'EOF'
Build the PaperTerm AppLoad bundle with pinned libvterm source.

Usage: build-paperterm.sh [--sdk-root DIRECTORY] [--clean]
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --sdk-root) (($# >= 2)) || die "--sdk-root requires a value"; sdk_root="$2"; shift 2 ;;
    --clean) clean=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

mapfile -t environment_files < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#environment_files[@]} == 1 )) || die "expected one SDK environment file under $sdk_root"
command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"
command -v perl >/dev/null || die "perl is required to generate libvterm encoding tables"
rsvg_binary="$(command -v rsvg-convert)" || die "rsvg-convert is required to render the AppLoad icon"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v tar >/dev/null || die "tar is required"

if $clean; then rm -rf "$build_directory"; fi
if [[ ! -d "$dependency_directory/.git" ]]; then
  mkdir -p "$(dirname "$dependency_directory")"
  git clone --filter=blob:none --no-checkout "$LIBVTERM_REPOSITORY" "$dependency_directory"
fi
git -C "$dependency_directory" fetch --quiet origin "$LIBVTERM_COMMIT"
git -C "$dependency_directory" checkout --quiet --detach "$LIBVTERM_COMMIT"
[[ "$(git -C "$dependency_directory" rev-parse HEAD)" == "$LIBVTERM_COMMIT" ]] \
  || die "libvterm checkout did not match the pinned commit"
[[ -f "$dependency_directory/LICENSE" ]] || die "libvterm license was not found"
[[ -z "$(git -C "$dependency_directory" status --porcelain --untracked-files=no)" ]] \
  || die "libvterm tracked source has local changes"

font_archive="$font_dependency_directory/Noto.tar.xz"
mkdir -p "$font_dependency_directory"
if [[ ! -f "$font_archive" ]]; then
  temporary_archive="$font_archive.part"
  rm -f "$temporary_archive"
  curl --fail --location --retry 3 --output "$temporary_archive" "$NERD_FONTS_ARCHIVE_URL"
  printf '%s  %s\n' "$NERD_FONTS_ARCHIVE_SHA256" "$temporary_archive" | sha256sum --check --status \
    || { rm -f "$temporary_archive"; die "Nerd Fonts archive checksum did not match"; }
  mv "$temporary_archive" "$font_archive"
fi
printf '%s  %s\n' "$NERD_FONTS_ARCHIVE_SHA256" "$font_archive" | sha256sum --check --status \
  || die "cached Nerd Fonts archive checksum did not match"
font_extract_directory="$font_dependency_directory/extracted"
rm -rf "$font_extract_directory"
mkdir -p "$font_extract_directory"
tar -xJf "$font_archive" -C "$font_extract_directory" "$NERD_FONT_FILE" LICENSE_OFL.txt
printf '%s  %s\n' "$NERD_FONT_SHA256" "$font_extract_directory/$NERD_FONT_FILE" | sha256sum --check --status \
  || die "extracted Nerd Font checksum did not match"

for table in "$dependency_directory"/src/encoding/*.tbl; do
  output="${table%.tbl}.inc"
  perl -CSD "$dependency_directory/tbl2inc_c.pl" "$table" > "$output"
done

# shellcheck disable=SC1090
source "${environment_files[0]}"
export LANG=C.utf8
export LC_ALL=C.utf8
rcc_binary="$OECORE_NATIVE_SYSROOT/usr/libexec/rcc"
[[ -x "$rcc_binary" ]] || die "Qt resource compiler not found after SDK activation"

mkdir -p "$build_directory/backend"
mkdir -p "$build_directory/fonts"
mkdir -p "$build_directory/objects"
(
  cd "$REPOSITORY_ROOT/src/paperterm"
  "$rcc_binary" --binary -o "$build_directory/resources.rcc" application.qrc
)
cp "$REPOSITORY_ROOT/src/paperterm/packaging/manifest.json" "$build_directory/manifest.json"
"$rsvg_binary" --width 100 --height 100 \
  --output "$build_directory/icon.png" \
  "$REPOSITORY_ROOT/src/paperterm/packaging/icon.svg"
cp "$dependency_directory/LICENSE" "$build_directory/LICENSE.libvterm"
install -m 0644 "$font_extract_directory/$NERD_FONT_FILE" "$build_directory/fonts/$NERD_FONT_FILE"
install -m 0644 "$font_extract_directory/LICENSE_OFL.txt" "$build_directory/LICENSE.nerd-fonts.txt"

read -r -a compiler <<< "$CC"
read -r -a json_c_cflags <<< "$(pkg-config --cflags json-c)"
mapfile -t libvterm_sources < <(find "$dependency_directory/src" -maxdepth 1 -type f -name '*.c' -print | sort)
(( ${#libvterm_sources[@]} > 0 )) || die "libvterm sources were not found"
app_object="$build_directory/objects/paperterm-backend.o"
"${compiler[@]}" -c \
  -std=c11 -Os -Wall -Wextra -Werror \
  -I"$dependency_directory/include" -I"$dependency_directory/src" \
  "${json_c_cflags[@]}" \
  "$REPOSITORY_ROOT/src/paperterm/backend/paperterm-backend.c" \
  -o "$app_object"

libvterm_objects=()
for source in "${libvterm_sources[@]}"; do
  object="$build_directory/objects/libvterm-$(basename "${source%.c}").o"
  "${compiler[@]}" -c -std=c99 -Os -Wall -Wpedantic \
    -I"$dependency_directory/include" -I"$dependency_directory/src" \
    "$source" -o "$object"
  libvterm_objects+=("$object")
done

"${compiler[@]}" "$app_object" "${libvterm_objects[@]}" \
  -ljson-c -lutil \
  -o "$build_directory/backend/entry"

[[ -s "$build_directory/resources.rcc" ]] || die "resource bundle was not created"
[[ -x "$build_directory/backend/entry" ]] || die "backend was not created"
[[ -s "$build_directory/icon.png" ]] || die "AppLoad icon was not created"
printf 'PaperTerm AppLoad bundle complete: %s\n' "$build_directory"
ls -l "$build_directory/icon.png" "$build_directory/manifest.json" "$build_directory/resources.rcc" \
  "$build_directory/backend/entry" "$build_directory/fonts/$NERD_FONT_FILE" \
  "$build_directory/LICENSE.libvterm" "$build_directory/LICENSE.nerd-fonts.txt"
