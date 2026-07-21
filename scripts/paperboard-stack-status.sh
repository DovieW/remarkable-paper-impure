#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
host="${PAPERBOARD_TRUENAS_HOST:-}"
dataset="containers/paperboard"
tablet_host="${REMARKABLE_HOST:-remarkable-tailnet}"
openclaw_host="${OPENCLAW_HOST:-openclaw}"
client_env="${PAPERBOARD_CLIENT_ENV:-$ROOT/secrets/clients/local-agent.env}"
failures=0
warnings=0

usage() {
  cat <<'EOF'
Verify the deployed Paperboard, Remote, NAS, VM, relay, and tablet stack.

Usage:
  paperboard-stack-status.sh --host USER@NAS [--dataset POOL/DATASET]
      [--tablet-host SSH_ALIAS] [--openclaw-host SSH_ALIAS]
      [--client-env IGNORED_ENV_FILE]

The report emits only pass/fail summaries. It never prints tokens, private
tailnet names, addresses, device identifiers, or response bodies.
EOF
}

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 2; }
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die "--host requires a value"; host=$2; shift 2 ;;
    --dataset) (($# >= 2)) || die "--dataset requires a value"; dataset=$2; shift 2 ;;
    --tablet-host) (($# >= 2)) || die "--tablet-host requires a value"; tablet_host=$2; shift 2 ;;
    --openclaw-host) (($# >= 2)) || die "--openclaw-host requires a value"; openclaw_host=$2; shift 2 ;;
    --client-env) (($# >= 2)) || die "--client-env requires a value"; client_env=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $host ]] || die "--host is required (or set PAPERBOARD_TRUENAS_HOST in an ignored environment)"
[[ $host != -* && $host != *$'\n'* ]] || die "invalid SSH host"
[[ $dataset =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || die "invalid dataset"
for command in curl jq ssh; do command -v "$command" >/dev/null || die "missing prerequisite: $command"; done

printf '%s\n' '[TrueNAS and private services]'
if report="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" sh -s -- "$dataset" <<'REMOTE'
set -eu
dataset=$1
app_state() {
  midclt call app.query "[[\"name\",\"=\",\"$1\"]]" | jq -r 'if length == 1 then .[0].state else "MISSING" end'
}
printf 'memory=%s\n' "$(midclt call system.info | jq -r 'if .physmem >= 30000000000 then "ok" else "low" end')"
printf 'paperboard=%s\n' "$(app_state paperboard-relay)"
printf 'tailscale=%s\n' "$(app_state tailscale)"
printf 'terminus=%s\n' "$(app_state terminus)"
printf 'relay_health=%s\n' "$(curl -fsS --max-time 5 http://127.0.0.1:8787/healthz >/dev/null 2>&1 && echo ok || echo failed)"
printf 'remote_health=%s\n' "$(curl -fsS --max-time 5 http://127.0.0.1:4174/remote/api/session >/dev/null 2>&1 && echo ok || echo failed)"
remote_capture=failed
temporary=$(mktemp /tmp/paperboard-status-frame.XXXXXX)
trap 'rm -f "$temporary"' EXIT INT TERM
session=$(curl -fsS --max-time 5 http://127.0.0.1:4174/remote/api/session 2>/dev/null || true)
token=$(printf '%s' "$session" | jq -r '.token // empty')
if [ -n "$token" ] && curl -fsS --max-time 15 -H "x-paper-remote-token: $token" \
  http://127.0.0.1:4174/remote/api/frame -o "$temporary" 2>/dev/null \
  && [ "$(od -An -tx1 -N8 "$temporary" | tr -d ' \n')" = 89504e470d0a1a0a ]; then
  remote_capture=ok
fi
printf 'remote_capture=%s\n' "$remote_capture"
rm -f "$temporary"
trap - EXIT INT TERM
printf 'terminus_health=%s\n' "$(curl -fsS --max-time 5 http://127.0.0.1:2300/ >/dev/null 2>&1 && echo ok || echo failed)"
printf 'admin_loopback=%s\n' "$(ss -H -ltn '( sport = :8788 )' | awk '{print $4}' | grep -Eq '^(127\.0\.0\.1|\[::1\]):8788$' && ! ss -H -ltn '( sport = :8788 )' | awk '{print $4}' | grep -Evq '^(127\.0\.0\.1|\[::1\]):8788$' && echo ok || echo failed)"
serve=$(/usr/bin/sudo -n docker exec ix-tailscale-tailscale-1 tailscale serve status --json 2>/dev/null || printf '{}')
printf 'serve=%s\n' "$(printf '%s' "$serve" | jq -r 'if (tostring | contains(":8787")) and (tostring | contains("/remote")) and (tostring | contains(":8443")) then "ok" else "failed" end')"
printf 'funnel=%s\n' "$(printf '%s' "$serve" | jq -r 'if ([.. | objects | .AllowFunnel? // empty] | any(. == true)) then "enabled" else "off" end')"
printf 'snapshot_policy=%s\n' "$(midclt call pool.snapshottask.query | jq -r --arg dataset "$dataset" 'if any(.[]; .dataset == $dataset and .enabled == true and .lifetime_value == 14 and .lifetime_unit == "DAY") then "ok" else "missing" end')"
printf 'remote_disarmed=%s\n' "$(/usr/bin/sudo -n test -e "/mnt/$dataset/remote-control/remote.disabled" && echo yes || echo no)"
vm=$(midclt call vm.query '[["name","=","openclaw"]]')
printf 'vm=%s\n' "$(printf '%s' "$vm" | jq -r 'if length == 1 and .[0].status.state == "RUNNING" and .[0].autostart == true and .[0].memory >= 8192 then "ok" else "failed" end')"
REMOTE
)"; then
  check_value() {
    local key=$1 expected=$2 label=$3 value
    value="$(sed -n "s/^${key}=//p" <<<"$report")"
    if [[ $value == "$expected" ]]; then pass "$label"; else fail "$label"; fi
  }
  check_value memory ok 'NAS memory is at least 30 GB'
  check_value paperboard RUNNING 'Paperboard TrueNAS app is running'
  check_value tailscale RUNNING 'Tailscale TrueNAS app is running'
  check_value terminus RUNNING 'Terminus TrueNAS app is running'
  check_value relay_health ok 'relay is healthy on NAS loopback'
  check_value remote_health ok 'Remote is healthy on NAS loopback'
  if [[ $(sed -n 's/^remote_capture=//p' <<<"$report") == ok ]]; then
    pass 'Remote captured a live PNG from the tablet'
  else
    warn 'tablet is unavailable for a live Remote capture (wake, unlock, and check its network)'
  fi
  check_value terminus_health ok 'Terminus responds on NAS loopback'
  check_value admin_loopback ok 'relay admin listener is loopback-only'
  check_value serve ok 'private Serve handlers include relay, Remote, and Terminus'
  check_value funnel off 'Tailscale Funnel is disabled'
  if [[ $(sed -n 's/^snapshot_policy=//p' <<<"$report") == ok ]]; then pass 'daily 14-day snapshot policy is enabled'; else warn 'daily 14-day snapshot policy is missing'; fi
  if [[ $(sed -n 's/^remote_disarmed=//p' <<<"$report") == yes ]]; then pass 'Remote input kill switch is engaged'; else warn 'Remote input is armed'; fi
  check_value vm ok 'OpenClaw VM is running, autostarts, and has at least 8 GiB RAM'
else
  fail 'TrueNAS status probe completed'
fi

printf '%s\n' '[OpenClaw and tablet]'
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$openclaw_host" \
  'systemctl is-active --quiet openclaw.service && systemctl is-enabled --quiet openclaw.service' 2>/dev/null; then
  pass 'OpenClaw gateway is active and enabled'
else
  fail 'OpenClaw gateway is active and enabled'
fi

if identity="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$tablet_host" '
  set -eu
  for unit in paperboard-tailscale.service paperboard-tailscale-serve.service dropbear-loopback.socket; do
    systemctl is-active --quiet "$unit"
    systemctl is-enabled --quiet "$unit"
  done
  printf "%s|%s" "$(hostname)" "$(uname -m)"
' 2>/dev/null)" && [[ $identity == imx93-tatsu\|aarch64 ]]; then
  pass 'Paper Pure is reachable and persistent tunnel services are active'
else
  warn 'Paper Pure is offline; persistent tunnel services could not be verified'
fi

printf '%s\n' '[Relay acknowledgement]'
if [[ -f $client_env && ! -L $client_env && -r $client_env ]]; then
  # shellcheck disable=SC1090
  if status="$( (set -a; source "$client_env"; set +a; curl -fsS --max-time 10 -H "Authorization: Bearer $PAPERBOARD_TOKEN" "${PAPERBOARD_URL%/}/v2/devices/$PAPERBOARD_DEVICE/status") )" 2>/dev/null \
    && jq -e '.online == true and (.last_ack_cursor | type == "number") and (.cursor | type == "number")' >/dev/null <<<"$status"; then
    pass 'tablet heartbeat is recent and acknowledgement state is readable'
  else
    warn 'tablet heartbeat is not recent (Paperboard may be closed or the tablet may be asleep)'
  fi
else
  warn 'ignored local client environment is unavailable; relay acknowledgement was not checked'
fi

printf 'Summary: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
