#!/usr/bin/env bash
set -Eeuo pipefail

readonly appload_url=https://github.com/asivery/rm-appload.git
readonly appload_commit=123c29eb2fa6d1025cb3fa1b47bece6cee0a74f6
readonly xovi_commit=2b99649f5e4fd6288be7792a8570bd16418adb70
readonly root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly output="$root/build/appload-control"

for tool in git make python3 qmake6 rcc; do
  command -v "$tool" >/dev/null || { echo "missing build prerequisite: $tool" >&2; exit 1; }
done
mkdir -p "$root/build"
rm -rf "$output"
git clone --filter=blob:none "$appload_url" "$output/appload"
git -C "$output/appload" checkout --detach "$appload_commit"
git -C "$output/appload" apply --check "$root/patches/appload/0001-root-only-launch-inbox.patch"
git -C "$output/appload" apply "$root/patches/appload/0001-root-only-launch-inbox.patch"

if [[ -n ${XOVI_REPO:-} ]]; then
  test "$(git -C "$XOVI_REPO" rev-parse HEAD)" = "$xovi_commit" || {
    echo "XOVI_REPO is not at the reviewed commit $xovi_commit" >&2
    exit 1
  }
else
  git clone --filter=blob:none https://github.com/asivery/xovi.git "$output/xovi"
  git -C "$output/xovi" checkout --detach "$xovi_commit"
  export XOVI_REPO="$output/xovi"
fi
(cd "$output/appload/xovi" && ./make.sh)
sha256sum "$output/appload/xovi/appload.so" >"$output/appload.so.sha256"
echo "Built $output/appload/xovi/appload.so"
