#!/usr/bin/env bash
set -Eeuo pipefail

host=remarkable-usb
backup=
dry_run=false
while (($#)); do
  case "$1" in
    --host) host=${2:?missing host}; shift 2 ;;
    --backup) backup=${2:?missing backup filename}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "usage: $0 --backup appload.so.TIMESTAMP [--host SSH_ALIAS] [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ $backup =~ ^appload\.so\.[0-9]{8}T[0-9]{6}Z$ ]] || { echo "invalid backup filename" >&2; exit 2; }
ssh -o BatchMode=yes -- "$host" "test \"\$(hostname)\" = imx93-tatsu && test -f '/home/root/.local/share/paperboard/backups/$backup'"
if $dry_run; then
  echo "Would restore $backup and restart the stock UI."
  exit 0
fi
ssh -- "$host" "set -eu
  install -m 0755 '/home/root/.local/share/paperboard/backups/$backup' /home/root/xovi/extensions.d/appload.so
  systemctl restart xochitl"
echo "Restored upstream AppLoad. The tablet must be unlocked after the restart."
