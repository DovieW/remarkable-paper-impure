#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
cd "$ROOT"

for command_name in git node pnpm rg shellcheck; do
  command -v "$command_name" >/dev/null || {
    printf 'host-check.sh: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

bash -n scripts/*.sh scripts/remarkable
shellcheck --severity=error scripts/*.sh scripts/remarkable
scripts/bootstrap-ssh.sh --dry-run
pnpm check
pnpm test
node - <<'NODE'
const fs = require("fs");
const registry = require("./packages/core/dist/operations.js").operationRegistry;
for (const key of ["id", "cli", "mcp"]) {
  const values = registry.map((item) => item[key]);
  if (new Set(values).size !== values.length) throw new Error(`duplicate operation ${key}`);
}
const routes = registry.map((item) => `${item.method} ${item.path}`);
if (new Set(routes).size !== routes.length) throw new Error("duplicate operation method/path");
for (const path of [
  "config/compatibility.json",
  "src/paperboard/packaging/manifest.json",
  "src/paperterm/packaging/manifest.json",
]) JSON.parse(fs.readFileSync(path, "utf8"));
const compatibility = JSON.parse(fs.readFileSync("config/compatibility.json", "utf8"));
if (!compatibility.approved_os || !Object.keys(compatibility.approved_os).length) {
  throw new Error("no approved OS release");
}
for (const path of ["src/paperboard/packaging/icon.svg", "src/paperterm/packaging/icon.svg"]) {
  const svg = fs.readFileSync(path, "utf8");
  if (!svg.includes('<svg') || !svg.includes('viewBox="0 0 100 100"')) {
    throw new Error(`${path} is not a 100x100 SVG source`);
  }
}
NODE
grep -Fq 'interval: 60 * 60 * 1000' src/paperboard/qml/Main.qml
grep -Fq 'paperboard admin provider set' scripts/configure-paperboard-trmnl-hosted.sh
grep -Fq 'paperboard admin provider set' scripts/configure-paperboard-terminus-local.sh
scripts/scan-repository.sh
git diff --check

printf 'Host-only checks passed. No device or deployment endpoint was contacted.\n'
