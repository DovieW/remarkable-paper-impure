#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${PAPERBOARD_TRUENAS_HOST:-}"
dataset="containers/paperboard"
app_name="paperboard-relay"
dry_run=false
temporary=""

usage() {
  cat <<'EOF'
Build and deploy the Paperboard relay as a private TrueNAS custom app.

Usage:
  deploy-paperboard-relay-truenas.sh --host USER@HOST [--dataset DATASET]
      [--dry-run]

The prepared dataset must contain data/, ssh/, secrets/, and config/
as described in docs/relay.md. Both container ports bind to NAS loopback;
Tailscale Serve exposes only the device API on private HTTPS port 8787.
EOF
}
die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
cleanup() {
  [[ -z "$temporary" || ! -d "$temporary" ]] || {
    find "$temporary" -mindepth 1 -delete
    rmdir "$temporary"
  }
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --dataset) (($# >= 2)) || die "--dataset requires a value"; dataset=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $host ]] || die "--host is required (or set PAPERBOARD_TRUENAS_HOST in an ignored shell environment)"
[[ $host != -* && $host != *$'\n'* ]] || die "invalid SSH host"
[[ $dataset =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || die "invalid dataset"
for command in docker gzip jq ssh; do command -v "$command" >/dev/null || die "missing prerequisite: $command"; done

release="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
image="paperboard-relay:$release"
mountpoint="/mnt/$dataset"
template="$ROOT/deploy/relay/compose.truenas-app.yml"
[[ -f $template ]] || die "TrueNAS Compose template is missing"

if $dry_run; then
  printf 'Would build and transfer %s directly to %s without a registry.\n' "$image" "$host"
  printf 'Would install/update %s using prepared dataset %s.\n' "$app_name" "$mountpoint"
  printf 'Would expose device API on private Tailscale HTTPS port 8787; admin stays on loopback.\n'
  printf 'Dry run complete: no image, app, or Tailscale state was changed.\n'
  exit 0
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
version="$(ssh "${ssh_options[@]}" "$host" 'midclt call system.info | jq -r .version')"
[[ $version == 25.* ]] || die "unsupported TrueNAS release: $version"
ssh "${ssh_options[@]}" "$host" "
  /usr/bin/sudo -n docker inspect ix-tailscale-tailscale-1 >/dev/null
  /usr/bin/sudo -n test -d '$mountpoint/data' -a -d '$mountpoint/ssh' -a -d '$mountpoint/secrets' -a -d '$mountpoint/config'
  /usr/bin/sudo -n test -f '$mountpoint/secrets/master_key' -a -f '$mountpoint/secrets/admin_token'
  /usr/bin/sudo -n test -f '$mountpoint/secrets/tablet_ssh_key' -a -f '$mountpoint/config/tablet-bridge.conf'
" || die "TrueNAS dataset is not prepared; follow docs/relay.md"

printf 'Building the pinned relay image.\n'
docker build -q -f "$ROOT/apps/relay/Dockerfile" -t "$image" "$ROOT" >/dev/null
printf 'Transferring the image directly to TrueNAS (no Docker Hub).\n'
docker save "$image" | gzip -1 | ssh "${ssh_options[@]}" "$host" 'gzip -dc | /usr/bin/sudo -n docker load >/dev/null'

temporary="$(mktemp -d)"
sed -e "s|__PAPERBOARD_IMAGE__|$image|g" -e "s|__PAPERBOARD_DATASET__|$mountpoint|g" \
  "$template" > "$temporary/compose.yml"
scp "${ssh_options[@]}" "$temporary/compose.yml" "$host:paperboard-relay-compose.yml" >/dev/null

ssh "${ssh_options[@]}" "$host" sh -s -- "$mountpoint" "$app_name" <<'REMOTE'
set -eu
mountpoint=$1
app_name=$2
/usr/bin/sudo -n install -m 0600 paperboard-relay-compose.yml "$mountpoint/config/compose.yml"
unlink paperboard-relay-compose.yml
dns=$(/usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')
test -n "$dns"
printf 'PAPERBOARD_PUBLIC_BASE_URL=https://%s:8787\n' "$dns" | /usr/bin/sudo -n tee "$mountpoint/config/relay.env" >/dev/null
/usr/bin/sudo -n chmod 0600 "$mountpoint/config/relay.env"
if midclt call app.query "[[\"id\",\"=\",\"$app_name\"]]" | jq -e 'length > 0' >/dev/null; then
  payload=$(/usr/bin/sudo -n cat "$mountpoint/config/compose.yml" | jq -Rs '{custom_compose_config_string:.}')
  midclt call -j app.update "$app_name" "$payload" >/dev/null
else
  payload=$(/usr/bin/sudo -n cat "$mountpoint/config/compose.yml" | jq -Rs --arg name "$app_name" '{app_name:$name,custom_app:true,custom_compose_config_string:.}')
  midclt call -j app.create "$payload" >/dev/null
fi
for attempt in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:8787/healthz >/dev/null
/usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve --bg --https=8787 http://127.0.0.1:8787 >/dev/null
REMOTE

private_url="$(ssh "${ssh_options[@]}" "$host" "/usr/bin/sudo -n awk -F= '/^PAPERBOARD_PUBLIC_BASE_URL=/{print \$2}' '$mountpoint/config/relay.env'")"
curl -fsS "$private_url/healthz" >/dev/null || die "private Tailscale endpoint is not healthy"
printf 'TrueNAS Paperboard relay is healthy over private Tailscale HTTPS.\n'
