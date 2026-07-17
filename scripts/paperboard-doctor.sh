#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${REMARKABLE_HOST:-remarkable-usb}"
relay_url="${PAPERBOARD_URL:-}"

while (($#)); do
  case "$1" in
    --host) host=${2:?--host requires a value}; shift 2 ;;
    --relay-url) relay_url=${2:?--relay-url requires a value}; shift 2 ;;
    -h|--help) echo 'Usage: paperboard-doctor.sh [--host ALIAS] [--relay-url URL]'; exit 0 ;;
    *) echo "paperboard-doctor.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
check() { if "$@"; then pass "$*"; else printf 'FAIL  %s\n' "$*"; fail=1; fi; }

check bash -n "$ROOT"/scripts/*.sh
check node -e 'const f=require("fs"); JSON.parse(f.readFileSync(process.argv[1],"utf8"))' "$ROOT/config/compatibility.json"

identity=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'printf "%s|%s|" "$(hostname)" "$(uname -m)"; sed -n '\''s/^IMG_VERSION="\(.*\)"/\1/p'\'' /etc/os-release' 2>/dev/null || true)
IFS='|' read -r platform architecture os_version <<<"$identity"
if [[ $platform == imx93-tatsu && $architecture == aarch64 ]]; then pass "Paper Pure identity on $host"; else printf 'FAIL  target identity did not match Paper Pure\n'; fail=1; fi
if node -e 'const c=require(process.argv[1]); process.exit(c.approved_os[process.argv[2]] ? 0 : 1)' "$ROOT/config/compatibility.json" "$os_version"; then pass "OS is explicitly approved"; else printf 'FAIL  OS is not approved by compatibility manifest\n'; fail=1; fi

if status=$(REMARKABLE_HOST="$host" "$ROOT/scripts/tablet-companion.sh" status 2>/dev/null); then
  node -e 'const s=JSON.parse(process.argv[1]); console.log(`PASS  companion foreground=${s.foreground} screenshot=${s.screenshot} input=${s.input_helper}`)' "$status"
else
  warn "tablet companion is unavailable"
fi

ssh -o BatchMode=yes "$host" 'test "$(stat -c %a /home/root/.ssh)" = 700 && test "$(stat -c %a /home/root/.ssh/authorized_keys)" = 600' \
  && pass "SSH key file permissions" || { printf 'FAIL  SSH key file permissions\n'; fail=1; }

if [[ -n $relay_url ]]; then
  curl --fail --silent --show-error --max-time 10 "${relay_url%/}/healthz" >/dev/null && pass "relay health" || { printf 'FAIL  relay health\n'; fail=1; }
fi

exit "$fail"
