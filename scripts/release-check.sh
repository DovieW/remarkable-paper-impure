#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scripts/host-check.sh
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
scripts/build-paperboard.sh --clean
node -e 'const fs=require("fs"); const b=fs.readFileSync(process.argv[1]); if (b.length < 24 || b.subarray(1,4).toString() !== "PNG" || b.readUInt32BE(16) !== 100 || b.readUInt32BE(20) !== 100) process.exit(1)' \
  build/paperboard-tatsu/icon.png
scripts/test-paperterm.sh
scripts/package-tablet-apps.sh --version release-check --skip-build
first_package_hashes="$(sha256sum build/releases/release-check/*.tar.gz)"
scripts/package-tablet-apps.sh --version release-check --skip-build >/dev/null
second_package_hashes="$(sha256sum build/releases/release-check/*.tar.gz)"
[[ "$first_package_hashes" == "$second_package_hashes" ]] || {
  echo 'release-check.sh: tablet app archives are not reproducible' >&2
  exit 1
}

echo 'Paperboard, PaperTerm, and Chat release checks passed.'
