#!/bin/sh
set -eu

if [ -n "${PAPERBOARD_MASTER_KEY_FILE:-}" ]; then
  PAPERBOARD_MASTER_KEY=$(cat "$PAPERBOARD_MASTER_KEY_FILE")
  export PAPERBOARD_MASTER_KEY
  unset PAPERBOARD_MASTER_KEY_FILE
fi
if [ -n "${PAPERBOARD_ADMIN_TOKEN_FILE:-}" ]; then
  PAPERBOARD_ADMIN_TOKEN=$(cat "$PAPERBOARD_ADMIN_TOKEN_FILE")
  export PAPERBOARD_ADMIN_TOKEN
  unset PAPERBOARD_ADMIN_TOKEN_FILE
fi
if [ -n "${PAPERBOARD_TABLET_SSH_KEY_FILE:-}" ]; then
  su-exec paperboard:paperboard sh -c \
    'umask 077; cat "$1" > /tmp/paperboard-tablet-ssh-key' \
    paperboard-key-copy "$PAPERBOARD_TABLET_SSH_KEY_FILE"
  unset PAPERBOARD_TABLET_SSH_KEY_FILE
fi

exec su-exec paperboard:paperboard "$@"
