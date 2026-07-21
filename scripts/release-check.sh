#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n scripts/*.sh
scripts/bootstrap-ssh.sh --dry-run
pnpm check
node -e '
  const fs=require("fs");
  const registry=require("./packages/core/dist/operations.js").operationRegistry;
  for (const key of ["id","cli","mcp"]) {
    const values=registry.map(item=>item[key]);
    if (new Set(values).size !== values.length) throw new Error(`duplicate operation ${key}`);
  }
  const routes=registry.map(item=>`${item.method} ${item.path}`);
  if (new Set(routes).size !== routes.length) throw new Error("duplicate operation method/path");
  const compatibility=JSON.parse(fs.readFileSync("config/compatibility.json","utf8"));
  if (!compatibility.approved_os || !Object.keys(compatibility.approved_os).length) throw new Error("no approved OS release");
'
grep -Fq 'interval: 60 * 60 * 1000' src/paperboard/qml/Main.qml
grep -Fq 'paperboard admin provider set' scripts/configure-paperboard-trmnl-hosted.sh
grep -Fq 'paperboard admin provider set' scripts/configure-paperboard-terminus-local.sh
scripts/deploy-paperboard-relay-truenas.sh --host USER@NAS --dry-run
scripts/manage-paperboard-truenas.sh prepare --host USER@NAS --dry-run
scripts/manage-paperboard-truenas.sh deploy --host USER@NAS --dry-run
scripts/manage-paperboard-truenas.sh snapshot-policy --host USER@NAS --dry-run
compose_root="$(mktemp -d)"
trap 'find "$compose_root" -mindepth 1 -delete; rmdir "$compose_root"' EXIT
mkdir -p "$compose_root/config"
touch "$compose_root/config/relay.env"
compose_check="$compose_root/compose.yml"
sed -e 's|__PAPERBOARD_IMAGE__|paperboard-relay:release-check|g' \
  -e 's|__PAPERBOARD_REMOTE_IMAGE__|paperboard-remote:release-check|g' \
  -e "s|__PAPERBOARD_DATASET__|$compose_root|g" \
  deploy/relay/compose.truenas-app.yml >"$compose_check"
docker compose -f "$compose_check" config --quiet
find "$compose_root" -mindepth 1 -delete
rmdir "$compose_root"
trap - EXIT
pnpm test
scripts/build-paperboard.sh --clean
node -e 'const fs=require("fs"); const b=fs.readFileSync(process.argv[1]); if (b.length < 24 || b.subarray(1,4).toString() !== "PNG" || b.readUInt32BE(16) !== 100 || b.readUInt32BE(20) !== 100) process.exit(1)' \
  build/paperboard-tatsu/icon.png
scripts/test-paperterm.sh
git diff --check

if git grep -Iq . -- ':!PERSONAL.md' ':!secrets/**' && git grep -IqE \
  '(pb_(device|client)_[A-Za-z0-9_-]{20,}|tskey-(auth|client)-[A-Za-z0-9]{10,}-[A-Za-z0-9]{10,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' \
  -- ':!PERSONAL.md' ':!secrets/**'; then
  echo 'release-check.sh: possible secret or private tailnet identifier found' >&2
  exit 1
fi

if rg -q --hidden --glob '!PERSONAL.md' --glob '!secrets/**' --glob '!.git/**' \
  '(pb_(device|client)_[A-Za-z0-9_-]{20,}|tskey-(auth|client)-[A-Za-z0-9]{10,}-[A-Za-z0-9]{10,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' .; then
  echo 'release-check.sh: possible secret found in the working tree' >&2
  exit 1
fi

if git grep -nE '[A-Za-z0-9.-]+\.ts\.net' -- ':!PERSONAL.md' ':!secrets/**' \
  | grep -Ev '(example-tailnet|PRIVATE-TAILNET-NAME)' >/dev/null; then
  echo 'release-check.sh: possible private tailnet hostname found in tracked files' >&2
  exit 1
fi

history_scan="$(mktemp)"
trap 'rm -f "$history_scan"' EXIT
git log -p --all -- . ':!PERSONAL.md' ':!secrets/**' >"$history_scan"
if rg -q \
  '(pb_(device|client)_[A-Za-z0-9_-]{20,}|tskey-(auth|client)-[A-Za-z0-9]{10,}-[A-Za-z0-9]{10,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' \
  "$history_scan"; then
  echo 'release-check.sh: possible secret found in Git history' >&2
  exit 1
fi
if rg '[A-Za-z0-9.-]+\.ts\.net' "$history_scan" \
  | grep -Ev '(example-tailnet|PRIVATE-TAILNET-NAME)' >/dev/null; then
  echo 'release-check.sh: possible private tailnet hostname found in Git history' >&2
  exit 1
fi

echo 'Paperboard v2 and PaperTerm release check passed.'
