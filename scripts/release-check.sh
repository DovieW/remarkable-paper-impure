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
pnpm test
scripts/build-paperboard.sh --clean
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

history_scan="$(mktemp)"
trap 'rm -f "$history_scan"' EXIT
git log -p --all -- . ':!PERSONAL.md' ':!secrets/**' >"$history_scan"
if rg -q \
  '(pb_(device|client)_[A-Za-z0-9_-]{20,}|tskey-(auth|client)-[A-Za-z0-9]{10,}-[A-Za-z0-9]{10,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' \
  "$history_scan"; then
  echo 'release-check.sh: possible secret found in Git history' >&2
  exit 1
fi

echo 'Paperboard v2 release check passed.'
