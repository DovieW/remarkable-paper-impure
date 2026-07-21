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

bash -n scripts/*.sh scripts/remarkable deploy/tablet/*.sh
shellcheck --severity=error scripts/*.sh scripts/remarkable deploy/tablet/*.sh
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

# A synchronous Xovi restart can tear down the SSH session and strand the
# tablet in stock mode. Keep the one reviewed, detached USB restart boundary.
xovi_start_path='/home/root/xovi/'"start"
mapfile -t xovi_start_callers < <(rg -F -l "$xovi_start_path" scripts)
if [[ "${#xovi_start_callers[@]}" -ne 1 \
  || "${xovi_start_callers[0]}" != scripts/restart-appload-runtime.sh ]]; then
  printf 'host-check.sh: direct Xovi restart escaped the USB safety helper\n' >&2
  printf '  %s\n' "${xovi_start_callers[@]}" >&2
  exit 1
fi
grep -Fq 'restart-appload-runtime.sh' scripts/deploy-paperboard.sh
grep -Fq 'restart-appload-runtime.sh' scripts/deploy-paperterm.sh
grep -Fq 'verify-appload-runtime.sh' scripts/deployment-summary.sh
grep -Fq '/home/root/xovi/scripts/post-start/50-paperboard-private-ssh.sh' \
  scripts/install-paperboard-tailscale-service.sh
grep -Fq 'paperboard-tailscale-health.timer' deploy/tablet/paperboard-private-ssh-activate.sh
if rg -F '/etc/systemd/system' scripts/install-paperboard-tailscale-service.sh \
    deploy/tablet/paperboard-private-ssh-*.sh; then
  echo 'host-check.sh: private SSH persistence must not use volatile /etc' >&2
  exit 1
fi
scripts/scan-repository.sh
git diff --check

printf 'Host-only checks passed. No device or deployment endpoint was contacted.\n'
