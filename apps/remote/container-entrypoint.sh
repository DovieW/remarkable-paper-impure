#!/bin/sh
set -eu

if [ -n "${PAPERBOARD_TABLET_SSH_KEY_FILE:-}" ]; then
  su-exec paperboard:paperboard sh -c \
    'umask 077; cat "$1" > /tmp/paperboard-tablet-ssh-key' \
    paperboard-key-copy "$PAPERBOARD_TABLET_SSH_KEY_FILE"
  unset PAPERBOARD_TABLET_SSH_KEY_FILE
fi

exec su-exec paperboard:paperboard "$@"
