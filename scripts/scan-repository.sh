#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SECRET_PATTERN='(pb_(device|client)_[A-Za-z0-9_-]{20,}|tskey-(auth|client)-[A-Za-z0-9]{10,}-[A-Za-z0-9]{10,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)'
readonly TAILNET_PATTERN='[A-Za-z0-9.-]+\.ts\.net'

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

cd "$ROOT"
command -v git >/dev/null || die "git is required"
command -v rg >/dev/null || die "ripgrep is required"

if git grep -Iq . -- ':!PERSONAL.md' ':!secrets/**' && git grep -IqE "$SECRET_PATTERN" \
  -- ':!PERSONAL.md' ':!secrets/**'; then
  die "possible secret or private tailnet credential found in tracked files"
fi

if rg -q --hidden --glob '!PERSONAL.md' --glob '!secrets/**' --glob '!.git/**' \
  "$SECRET_PATTERN" .; then
  die "possible secret found in the working tree"
fi

if git grep -nE "$TAILNET_PATTERN" -- ':!PERSONAL.md' ':!secrets/**' \
  | grep -Ev '(example-tailnet|PRIVATE-TAILNET-NAME)' >/dev/null; then
  die "possible private tailnet hostname found in tracked files"
fi

history_scan="$(mktemp)"
cleanup() { rm -f "$history_scan"; }
trap cleanup EXIT INT TERM
git log -p --all -- . ':!PERSONAL.md' ':!secrets/**' >"$history_scan"
if rg -q "$SECRET_PATTERN" "$history_scan"; then
  die "possible secret found in Git history"
fi
if rg "$TAILNET_PATTERN" "$history_scan" \
  | grep -Ev '(example-tailnet|PRIVATE-TAILNET-NAME)' >/dev/null; then
  die "possible private tailnet hostname found in Git history"
fi

printf 'Repository secret and private-tailnet scan passed.\n'
