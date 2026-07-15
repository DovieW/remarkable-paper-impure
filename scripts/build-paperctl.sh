#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"
output="${PAPERCTL_BINARY:-$REPOSITORY_ROOT/build/paperctl/paperctl-tap}"

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

mapfile -t environment_files < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#environment_files[@]} == 1 )) \
  || die "expected one SDK environment file under $sdk_root; run scripts/setup-paperboard-sdk.sh"

# shellcheck disable=SC1090
source "${environment_files[0]}"
export LANG=C.utf8
export LC_ALL=C.utf8

mkdir -p "$(dirname "$output")"
# Yocto intentionally exports CC as a compiler plus required target flags.
# shellcheck disable=SC2086
$CC -std=c11 -O2 -Wall -Wextra -Werror \
  "$REPOSITORY_ROOT/tools/paperctl-tap.c" -o "$output"
# shellcheck disable=SC2086
$STRIP "$output"
file "$output"
printf 'paperctl tap helper built: %s\n' "$output"
