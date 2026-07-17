#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
command_name="${1:-}"
[[ -z $command_name ]] || shift
host="${PAPERBOARD_TRUENAS_HOST:-}"
dataset="containers/paperboard"
source_data=""
source_container=""
snapshot=""
confirm=false
dry_run=false
temporary=""
remote_temporary=""
restart_container_on_exit=false

usage() {
  cat <<'EOF'
Manage the complete Paperboard TrueNAS lifecycle.

Usage:
  manage-paperboard-truenas.sh COMMAND --host USER@NAS [options]

Commands:
  prepare          Create the dataset layout and securely seed ignored config.
  migrate          Copy a stopped relay data directory/container to TrueNAS.
  deploy           Build and deploy Relay plus Remote through Tailscale Serve.
  status           Run the end-to-end stack status checks.
  snapshot         Create a named pre-change snapshot.
  snapshot-policy  Create/update daily snapshots retained for 14 days.
  rollback         Roll back to --snapshot NAME; requires --confirm.
  enable           Start the app and restore private Serve handlers.
  disable          Stop the app and remove its private Serve handlers.
  remote-arm       Enable bounded tap/swipe; requires --confirm.
  remote-disarm    Disable remote tap/swipe immediately.
  uninstall        Snapshot and remove only the app; requires --confirm.

Options:
  --host USER@NAS
  --dataset POOL/DATASET       Default: containers/paperboard
  --source-data DIRECTORY     For migrate; source must contain paperboard.sqlite.
  --source-container NAME     For migrate; container is paused by stop/start.
  --snapshot NAME             Snapshot name for rollback.
  --confirm                   Required for overwrite, rollback, arm, uninstall.
  --dry-run

Secrets are read only from ignored repository files and are never printed.
The dataset is never destroyed by this script.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }
cleanup() {
  if $restart_container_on_exit && [[ -n $source_container ]]; then
    docker start "$source_container" >/dev/null 2>&1 || true
  fi
  [[ -z $temporary || ! -d $temporary ]] || {
    find "$temporary" -mindepth 1 -delete
    rmdir "$temporary"
  }
  if [[ $remote_temporary == /tmp/paperboard-seed.* && -n $host ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- "$remote_temporary" <<'REMOTE' >/dev/null 2>&1 || true
set -eu
find "$1" -mindepth 1 -delete
rmdir "$1"
REMOTE
  fi
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --dataset) (($# >= 2)) || die "--dataset requires a value"; dataset=$2; shift 2 ;;
    --source-data) (($# >= 2)) || die "--source-data requires a value"; source_data=$2; shift 2 ;;
    --source-container) (($# >= 2)) || die "--source-container requires a value"; source_container=$2; shift 2 ;;
    --snapshot) (($# >= 2)) || die "--snapshot requires a value"; snapshot=$2; shift 2 ;;
    --confirm) confirm=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$command_name" in
  prepare|migrate|deploy|status|snapshot|snapshot-policy|rollback|enable|disable|remote-arm|remote-disarm|uninstall) ;;
  "") usage; exit 2 ;;
  *) die "unknown command: $command_name" ;;
esac
[[ -n $host ]] || die "--host is required (or set PAPERBOARD_TRUENAS_HOST in an ignored shell environment)"
[[ $host != -* && $host != *$'\n'* ]] || die "invalid SSH host"
[[ $dataset =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || die "invalid dataset"
[[ -z $snapshot || $snapshot =~ ^[A-Za-z0-9._:%+-]+$ ]] || die "invalid snapshot name"
mountpoint="/mnt/$dataset"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)

run_ssh() { ssh "${ssh_options[@]}" "$host" "$@"; }
app_exists() { run_ssh "midclt call app.query '[[\"name\",\"=\",\"paperboard-relay\"]]' | jq -e 'length == 1' >/dev/null"; }

prepare() {
  local required=(
    "$ROOT/secrets/paperboard-master-key"
    "$ROOT/secrets/paperboard-admin-token"
    "$ROOT/secrets/tablet-bridge/id_ed25519"
    "$ROOT/secrets/tablet-bridge/tablet-bridge.conf"
    "$ROOT/secrets/tablet-bridge/ssh/config"
    "$ROOT/secrets/tablet-bridge/ssh/known_hosts"
  )
  local file
  for file in "${required[@]}"; do [[ -s $file ]] || die "missing ignored prerequisite: ${file#"$ROOT/"}"; done
  if $dry_run; then
    printf 'Would prepare %s and seed restricted config on %s.\n' "$mountpoint" "$host"
    return
  fi

  run_ssh sh -s -- "$dataset" "$mountpoint" <<'REMOTE'
set -eu
dataset=$1
mountpoint=$2
if ! midclt call pool.dataset.query "[[\"name\",\"=\",\"$dataset\"]]" | jq -e 'length == 1' >/dev/null; then
  payload=$(jq -nc --arg name "$dataset" '{name:$name,type:"FILESYSTEM"}')
  midclt call pool.dataset.create "$payload" >/dev/null
fi
/usr/bin/sudo -n install -d -m 0750 -o root -g root "$mountpoint/config"
/usr/bin/sudo -n install -d -m 0711 -o root -g root "$mountpoint/secrets"
/usr/bin/sudo -n install -d -m 0700 -o 100 -g 101 "$mountpoint/data" "$mountpoint/ssh" "$mountpoint/remote-control"
/usr/bin/sudo -n install -m 0600 -o 100 -g 101 /dev/null "$mountpoint/remote-control/remote.disabled"
REMOTE

  remote_temporary="$(run_ssh 'mktemp -d /tmp/paperboard-seed.XXXXXX')"
  [[ $remote_temporary == /tmp/paperboard-seed.* ]] || die "unexpected remote temporary path"
  scp "${ssh_options[@]}" -q \
    "$ROOT/secrets/paperboard-master-key" \
    "$ROOT/secrets/paperboard-admin-token" \
    "$ROOT/secrets/tablet-bridge/id_ed25519" \
    "$ROOT/secrets/tablet-bridge/tablet-bridge.conf" \
    "$ROOT/secrets/tablet-bridge/ssh/config" \
    "$ROOT/secrets/tablet-bridge/ssh/known_hosts" \
    "$host:$remote_temporary/"
  run_ssh sh -s -- "$remote_temporary" "$mountpoint" <<'REMOTE'
set -eu
temporary=$1
mountpoint=$2
/usr/bin/sudo -n install -m 0400 -o root -g root "$temporary/paperboard-master-key" "$mountpoint/secrets/master_key"
/usr/bin/sudo -n install -m 0400 -o root -g root "$temporary/paperboard-admin-token" "$mountpoint/secrets/admin_token"
/usr/bin/sudo -n install -m 0400 -o 100 -g 101 "$temporary/id_ed25519" "$mountpoint/secrets/tablet_ssh_key"
/usr/bin/sudo -n install -m 0644 -o root -g root "$temporary/tablet-bridge.conf" "$mountpoint/config/tablet-bridge.conf"
/usr/bin/sudo -n install -m 0600 -o 100 -g 101 "$temporary/config" "$mountpoint/ssh/config"
/usr/bin/sudo -n install -m 0600 -o 100 -g 101 "$temporary/known_hosts" "$mountpoint/ssh/known_hosts"
find "$temporary" -mindepth 1 -delete
rmdir "$temporary"
REMOTE
  remote_temporary=""
  printf 'Prepared Paperboard dataset and restricted configuration.\n'
}

migrate() {
  [[ -z $source_data || -z $source_container ]] || die "choose only one migration source"
  [[ -n $source_data || -n $source_container ]] || die "migrate requires --source-data or --source-container"
  local source_was_running=false
  if [[ -n $source_container ]]; then
    command -v docker >/dev/null || die "docker is required for --source-container"
    docker inspect "$source_container" >/dev/null 2>&1 || die "source container does not exist"
    temporary="$(mktemp -d)"
    mkdir "$temporary/data"
    if [[ $(docker inspect -f '{{.State.Running}}' "$source_container") == true ]]; then
      source_was_running=true
      if ! $dry_run; then
        docker stop -t 20 "$source_container" >/dev/null
        restart_container_on_exit=true
      fi
    fi
    if ! $dry_run; then
      docker cp "$source_container:/data/." "$temporary/data/"
      if $source_was_running; then
        docker start "$source_container" >/dev/null
        restart_container_on_exit=false
      fi
    fi
    source_data="$temporary/data"
  fi
  [[ $dry_run == true || -s $source_data/paperboard.sqlite ]] || die "source does not contain paperboard.sqlite"
  if $dry_run; then
    printf 'Would snapshot, stop the app, and migrate data from %s to %s.\n' "${source_container:-$source_data}" "$mountpoint/data"
    return
  fi
  local existing
  existing="$(run_ssh "/usr/bin/sudo -n find '$mountpoint/data' -mindepth 1 -maxdepth 1 | wc -l")"
  if ((existing > 0)) && ! $confirm; then die "destination is not empty; rerun with --confirm after reviewing backups"; fi
  local snap
  snap="pre-migrate-$(date -u +%Y%m%dT%H%M%SZ)"
  run_ssh sh -s -- "$dataset" "$mountpoint" "$snap" <<'REMOTE'
set -eu
dataset=$1
mountpoint=$2
snapshot=$3
if midclt call app.query '[["name","=","paperboard-relay"]]' | jq -e 'length == 1' >/dev/null; then midclt call -j app.stop paperboard-relay >/dev/null; fi
if /usr/bin/sudo -n test -e "$mountpoint/data/paperboard.sqlite"; then
  payload=$(jq -nc --arg dataset "$dataset" --arg name "$snapshot" '{dataset:$dataset,name:$name}')
  midclt call pool.snapshot.create "$payload" >/dev/null
fi
/usr/bin/sudo -n find "$mountpoint/data" -mindepth 1 -delete
REMOTE
  tar -C "$source_data" -cf - . | run_ssh "/usr/bin/sudo -n tar -C '$mountpoint/data' -xf - && /usr/bin/sudo -n chown -R 100:101 '$mountpoint/data'"
  local local_hash remote_hash
  local_hash="$(sha256sum "$source_data/paperboard.sqlite" | cut -d' ' -f1)"
  remote_hash="$(run_ssh "/usr/bin/sudo -n sha256sum '$mountpoint/data/paperboard.sqlite' | cut -d' ' -f1")"
  [[ $local_hash == "$remote_hash" ]] || die "database checksum mismatch"
  app_exists && run_ssh 'midclt call -j app.start paperboard-relay >/dev/null'
  printf 'Migrated relay data with a verified database checksum.\n'
}

create_snapshot() {
  local name="${snapshot:-manual-$(date -u +%Y%m%dT%H%M%SZ)}"
  if $dry_run; then printf 'Would create %s@%s.\n' "$dataset" "$name"; return; fi
  run_ssh sh -s -- "$dataset" "$name" <<'REMOTE'
set -eu
payload=$(jq -nc --arg dataset "$1" --arg name "$2" '{dataset:$dataset,name:$name}')
midclt call pool.snapshot.create "$payload" >/dev/null
REMOTE
  printf 'Created a Paperboard dataset snapshot.\n'
}

snapshot_policy() {
  if $dry_run; then printf 'Would enable daily Paperboard snapshots retained for 14 days.\n'; return; fi
  run_ssh sh -s -- "$dataset" <<'REMOTE'
set -eu
dataset=$1
payload=$(jq -nc --arg dataset "$dataset" '{dataset:$dataset,recursive:false,lifetime_value:14,lifetime_unit:"DAY",enabled:true,naming_schema:"paperboard-auto-%Y-%m-%d_%H-%M",allow_empty:false,schedule:{minute:"15",hour:"03",dom:"*",month:"*",dow:"*"}}')
ids=$(midclt call pool.snapshottask.query | jq -r --arg dataset "$dataset" '.[] | select(.dataset == $dataset) | .id')
if [ -n "$ids" ]; then
  first=$(printf '%s\n' "$ids" | head -n1)
  midclt call pool.snapshottask.update "$first" "$payload" >/dev/null
else
  midclt call pool.snapshottask.create "$payload" >/dev/null
fi
REMOTE
  printf 'Daily snapshots are enabled with 14-day retention.\n'
}

serve_on() {
  run_ssh '/usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve --bg --https=8787 http://127.0.0.1:8787 >/dev/null; /usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve --bg --https=8787 --set-path=/remote http://127.0.0.1:4174 >/dev/null'
}

case "$command_name" in
  prepare) prepare ;;
  migrate) migrate ;;
  deploy)
    args=(--host "$host" --dataset "$dataset")
    $dry_run && args+=(--dry-run)
    "$ROOT/scripts/deploy-paperboard-relay-truenas.sh" "${args[@]}"
    ;;
  status)
    args=(--host "$host" --dataset "$dataset")
    "$ROOT/scripts/paperboard-stack-status.sh" "${args[@]}"
    ;;
  snapshot) create_snapshot ;;
  snapshot-policy) snapshot_policy ;;
  rollback)
    [[ -n $snapshot ]] || die "rollback requires --snapshot NAME"
    $confirm || die "rollback requires --confirm"
    $dry_run && { printf 'Would stop the app, roll back to %s@%s, and restart.\n' "$dataset" "$snapshot"; exit 0; }
    run_ssh "midclt call -j app.stop paperboard-relay >/dev/null; midclt call -j pool.snapshot.rollback '$dataset@$snapshot' '{}' >/dev/null; midclt call -j app.start paperboard-relay >/dev/null"
    serve_on
    printf 'Rolled back and restarted Paperboard.\n'
    ;;
  enable)
    $dry_run && { printf 'Would start Paperboard and restore its private Serve handlers.\n'; exit 0; }
    run_ssh 'midclt call -j app.start paperboard-relay >/dev/null'
    serve_on
    ;;
  disable)
    $dry_run && { printf 'Would stop Paperboard and remove HTTPS port 8787 Serve handlers.\n'; exit 0; }
    run_ssh 'midclt call -j app.stop paperboard-relay >/dev/null; /usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve --https=8787 off >/dev/null'
    ;;
  remote-arm)
    $confirm || die "remote-arm requires --confirm"
    $dry_run && { printf 'Would remove the Remote input kill switch.\n'; exit 0; }
    run_ssh "/usr/bin/sudo -n unlink '$mountpoint/remote-control/remote.disabled' 2>/dev/null || true"
    printf 'Remote bounded input is armed.\n'
    ;;
  remote-disarm)
    $dry_run && { printf 'Would install the Remote input kill switch.\n'; exit 0; }
    run_ssh "/usr/bin/sudo -n install -m 0600 -o 100 -g 101 /dev/null '$mountpoint/remote-control/remote.disabled'"
    printf 'Remote input is disarmed.\n'
    ;;
  uninstall)
    $confirm || die "uninstall requires --confirm"
    $dry_run && { printf 'Would snapshot and remove the app while retaining %s.\n' "$dataset"; exit 0; }
    snapshot="pre-uninstall-$(date -u +%Y%m%dT%H%M%SZ)"; create_snapshot
    run_ssh 'midclt call -j app.delete paperboard-relay '"'"'{"remove_images":false,"remove_ix_volumes":false,"force_remove_ix_volumes":false,"force_remove_custom_app":true}'"'"' >/dev/null; /usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve --https=8787 off >/dev/null'
    printf 'Removed the app; dataset and snapshot were retained.\n'
    ;;
esac
