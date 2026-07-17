#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="${0##*/}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$root/build/paperboard-mcp.mjs"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --output) (($# >= 2)) || die "--output requires a path"; output=$2; shift 2 ;;
    -h|--help) printf 'Usage: %s [--output PATH]\n' "$PROGRAM_NAME"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v pnpm >/dev/null || die "pnpm is required on the build host"
[[ -f "$root/pnpm-lock.yaml" ]] || die "run from a complete Paperboard checkout"
mkdir -p "$(dirname "$output")"

(
  cd "$root"
  pnpm exec esbuild apps/mcp/src/main.ts \
    --bundle \
    --platform=node \
    --format=esm \
    --target=node24 \
    --legal-comments=none \
    --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' \
    --outfile="$output"
)

chmod 600 "$output"
sha256sum "$output" > "$output.sha256"
printf 'Built Paperboard MCP bundle and checksum under ignored build/.\n'
