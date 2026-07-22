#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

version=""
output_root="$ROOT/build/releases"
skip_build=false

usage() {
  cat <<'EOF'
Build reproducible, checksummed Paperboard, PaperTerm, and Chat runtime archives.

Usage: package-tablet-apps.sh --version VERSION [--output DIRECTORY] [--skip-build]

The archives contain only runtime files, not SDK objects or owner configuration.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --version) (($# >= 2)) || die "--version requires a value"; version="$2"; shift 2 ;;
    --output) (($# >= 2)) || die "--output requires a value"; output_root="$2"; shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$version" ]] || die "--version is required"
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "version may contain only letters, numbers, dot, underscore, and hyphen"
for command_name in git gzip node sha256sum tar; do
  command -v "$command_name" >/dev/null || die "required command not found: $command_name"
done
tar --version 2>/dev/null | grep -Fq 'GNU tar' || die "GNU tar is required for reproducible archives"

if ! $skip_build; then
  "$ROOT/scripts/build-paperboard.sh" --clean
  "$ROOT/scripts/test-paperterm.sh"
  "$ROOT/scripts/build-chat.sh" --clean
fi

paperboard_bundle="$ROOT/build/paperboard-tatsu"
paperterm_bundle="$ROOT/build/paperterm-tatsu"
chat_bundle="$ROOT/build/chat-tatsu"
for required in \
  "$paperboard_bundle/manifest.json" "$paperboard_bundle/resources.rcc" \
  "$paperboard_bundle/icon.png" "$paperboard_bundle/backend/entry" \
  "$paperterm_bundle/manifest.json" "$paperterm_bundle/resources.rcc" \
  "$paperterm_bundle/icon.png" "$paperterm_bundle/backend/entry" \
  "$paperterm_bundle/fonts/NotoMonoNerdFontMono-Regular.ttf" \
  "$paperterm_bundle/LICENSE.libvterm" "$paperterm_bundle/LICENSE.nerd-fonts.txt"; do
  [[ -s "$required" ]] || die "runtime file is missing: $required"
done
for required in "$chat_bundle/manifest.json" "$chat_bundle/resources.rcc" "$chat_bundle/icon.png" "$chat_bundle/backend/entry"; do
  [[ -s "$required" ]] || die "runtime file is missing: $required"
done

release_directory="$output_root/$version"
staging_directory="$(mktemp -d)"
cleanup() { rm -rf "$staging_directory"; }
trap cleanup EXIT INT TERM
mkdir -p "$staging_directory/paperboard/backend" "$staging_directory/paperterm/backend" "$staging_directory/paperterm/fonts" "$staging_directory/chat/backend"
install -m 0644 "$paperboard_bundle/manifest.json" "$staging_directory/paperboard/manifest.json"
install -m 0644 "$paperboard_bundle/resources.rcc" "$staging_directory/paperboard/resources.rcc"
install -m 0644 "$paperboard_bundle/icon.png" "$staging_directory/paperboard/icon.png"
install -m 0755 "$paperboard_bundle/backend/entry" "$staging_directory/paperboard/backend/entry"
install -m 0644 "$paperterm_bundle/manifest.json" "$staging_directory/paperterm/manifest.json"
install -m 0644 "$paperterm_bundle/resources.rcc" "$staging_directory/paperterm/resources.rcc"
install -m 0644 "$paperterm_bundle/icon.png" "$staging_directory/paperterm/icon.png"
install -m 0755 "$paperterm_bundle/backend/entry" "$staging_directory/paperterm/backend/entry"
install -m 0644 "$paperterm_bundle/fonts/NotoMonoNerdFontMono-Regular.ttf" \
  "$staging_directory/paperterm/fonts/NotoMonoNerdFontMono-Regular.ttf"
install -m 0644 "$paperterm_bundle/LICENSE.libvterm" "$staging_directory/paperterm/LICENSE.libvterm"
install -m 0644 "$paperterm_bundle/LICENSE.nerd-fonts.txt" "$staging_directory/paperterm/LICENSE.nerd-fonts.txt"
install -m 0644 "$chat_bundle/manifest.json" "$staging_directory/chat/manifest.json"
install -m 0644 "$chat_bundle/resources.rcc" "$staging_directory/chat/resources.rcc"
install -m 0644 "$chat_bundle/icon.png" "$staging_directory/chat/icon.png"
install -m 0755 "$chat_bundle/backend/entry" "$staging_directory/chat/backend/entry"

mkdir -p "$release_directory"
paperboard_archive="$release_directory/paperboard-$version-tatsu.tar.gz"
paperterm_archive="$release_directory/paperterm-$version-tatsu.tar.gz"
chat_archive="$release_directory/chat-$version-tatsu.tar.gz"
for app in paperboard paperterm chat; do
  archive="$release_directory/$app-$version-tatsu.tar.gz"
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$staging_directory/$app" -cf - . | gzip -n -9 >"$archive"
  tar -tzf "$archive" >/dev/null || die "archive verification failed: $archive"
done

(
  cd "$release_directory"
  sha256sum "${paperboard_archive##*/}" "${paperterm_archive##*/}" "${chat_archive##*/}" >SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)

commit="$(git -C "$ROOT" rev-parse HEAD)"
dirty=false
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || dirty=true
node - "$release_directory" "$version" "$commit" "$dirty" "${paperboard_archive##*/}" "${paperterm_archive##*/}" "${chat_archive##*/}" <<'NODE'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const [directory, version, commit, dirtyText, ...artifacts] = process.argv.slice(2);
const files = artifacts.map((name) => {
  const bytes = fs.readFileSync(path.join(directory, name));
  return { name, bytes: bytes.length, sha256: crypto.createHash("sha256").update(bytes).digest("hex") };
});
const manifest = {
  schema_version: 1,
  version,
  target: { platform: "imx93-tatsu", architecture: "aarch64" },
  source: { commit, dirty: dirtyText === "true" },
  artifacts: files,
};
fs.writeFileSync(path.join(directory, "release-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
NODE

printf 'Tablet app release bundle complete: %s\n' "$release_directory"
printf '  %s\n  %s\n  %s\n  %s\n' \
  "$paperboard_archive" "$paperterm_archive" "$chat_archive" "$release_directory/SHA256SUMS" "$release_directory/release-manifest.json"
