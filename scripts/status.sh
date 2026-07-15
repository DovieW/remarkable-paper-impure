#!/usr/bin/env bash

set -Eeuo pipefail

host="${REMARKABLE_HOST:-remarkable}"

if (($# == 2)) && [[ "$1" == "--host" ]]; then
  host="$2"
elif (($#)); then
  printf 'Usage: %s [--host HOST]\n' "${0##*/}" >&2
  exit 2
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" '
  printf "%s\n" "[device]"
  printf "hostname="
  hostname
  printf "architecture="
  uname -m
  sed -n '\''s/^IMG_VERSION="\(.*\)"/os-image=\1/p'\'' /etc/os-release

  printf "%s\n" "[services]"
  for service in xochitl dropbear-wlan.socket; do
    printf "%s=" "$service"
    systemctl is-active "$service" 2>/dev/null || true
  done

  printf "%s\n" "[xochitl-mode]"
  pid=$(systemctl show --property MainPID --value xochitl.service)
  if test -n "$pid" && test "$pid" != 0 && test -r "/proc/$pid/environ"; then
    if tr "\0" "\n" < "/proc/$pid/environ" | grep -q "^LD_PRELOAD=/home/root/xovi/xovi.so$"; then
      echo xovi-appload
    else
      echo stock
    fi
  else
    echo stopped
  fi

  printf "%s\n" "[storage]"
  df -h / /home
  mount | grep " on / "

  printf "%s\n" "[vellum-packages]"
  if test -x /home/root/.vellum/bin/vellum; then
    /home/root/.vellum/bin/vellum list --installed 2>/dev/null
  else
    echo not-installed
  fi

  printf "%s\n" "[appload-apps]"
  if test -d /home/root/xovi/exthome/appload; then
    find /home/root/xovi/exthome/appload \
      \( -name manifest.json -o -name external.manifest.json \) -print \
      | while read -r manifest; do dirname "$manifest"; done \
      | while read -r directory; do basename "$directory"; done \
      | sort -u
  fi
'

