#!/usr/bin/env bash
set -Eeuo pipefail

readonly config_file="${PAPERBOARD_TABLET_BRIDGE_CONFIG:-/etc/paperboard/tablet-bridge.conf}"
test -r "$config_file" || { echo "tablet bridge configuration is unavailable" >&2; exit 1; }
# shellcheck disable=SC1090
. "$config_file"
: "${PAPERBOARD_TABLET_DEVICE_ID:?missing device id}"
: "${PAPERBOARD_TABLET_SSH_ALIAS:?missing SSH alias}"
: "${PAPERBOARD_TABLET_SSH_CONFIG:?missing SSH config}"

(($# >= 2)) || { echo "usage: paperboard-tablet-bridge DEVICE ACTION [ARG]" >&2; exit 2; }
device=$1; action=$2; shift 2
[[ $device == "$PAPERBOARD_TABLET_DEVICE_ID" ]] || { echo "unknown device" >&2; exit 1; }
case "$action" in
  status|apps|return|screenshot) (($# == 0)) || exit 2 ;;
  launch) (($# == 1)) || exit 2; [[ $1 =~ ^(external::)?[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}$ ]] || exit 2 ;;
  *) echo "unsupported tablet action" >&2; exit 2 ;;
esac

exec ssh -F "$PAPERBOARD_TABLET_SSH_CONFIG" \
  -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
  "$PAPERBOARD_TABLET_SSH_ALIAS" -- paperboard-control "$action" "$@"
