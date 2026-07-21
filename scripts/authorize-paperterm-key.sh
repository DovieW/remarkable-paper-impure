#!/usr/bin/env bash

set -Eeuo pipefail

public_key_file=""
authorized_keys="$HOME/.ssh/authorized_keys"
dry_run=false

die() { printf 'authorize-paperterm-key.sh: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --public-key) (($# >= 2)) || die "--public-key requires a file"; public_key_file="$2"; shift 2 ;;
    --authorized-keys) (($# >= 2)) || die "--authorized-keys requires a file"; authorized_keys="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) printf 'Usage: authorize-paperterm-key.sh --public-key FILE [--authorized-keys FILE] [--dry-run]\n'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$public_key_file" ]] || die "--public-key must name an existing file"
[[ "$authorized_keys" == "$HOME/.ssh/authorized_keys" ]] \
  || die "the destination must be the current user's authorized_keys file"
key_line="$(awk 'NF { count++; line=$1 " " $2 " paperterm@paper-pure"; if ($1 != "ssh-ed25519" || $2 !~ /^[A-Za-z0-9+\/=]+$/) exit 1 } END { if (count != 1) exit 1; print line }' "$public_key_file")" \
  || die "public-key file must contain exactly one Ed25519 key"

if $dry_run; then
  printf 'PaperTerm public key validation passed; authorized_keys was not changed.\n'
  exit 0
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$authorized_keys"
chmod 600 "$authorized_keys"
grep -Fqx "$key_line" "$authorized_keys" 2>/dev/null || printf '%s\n' "$key_line" >> "$authorized_keys"
printf 'PaperTerm public key authorized for the current WSL account.\n'
