#!/usr/bin/env bash
set -Eeuo pipefail

readonly appload_url=https://github.com/asivery/rm-appload.git
readonly appload_commit=123c29eb2fa6d1025cb3fa1b47bece6cee0a74f6
readonly xovi_commit=2b99649f5e4fd6288be7792a8570bd16418adb70
readonly root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly output="$root/build/appload-control"
sdk_root=${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}

while (($#)); do
  case "$1" in
    --sdk-root)
      (($# >= 2)) || { echo "--sdk-root requires a value" >&2; exit 2; }
      sdk_root=$2
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--sdk-root DIRECTORY]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

mapfile -t environment_files < <(
  find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print
)
(( ${#environment_files[@]} == 1 )) || {
  echo "expected one SDK environment file under $sdk_root; run scripts/setup-paperboard-sdk.sh" >&2
  exit 1
}

# AppLoad is injected into the tablet's aarch64 stock UI. A native WSL build
# can compile successfully but cannot load on the tablet, so always activate
# the official Paper Pure cross-compilation SDK here.
# shellcheck disable=SC1090
source "${environment_files[0]}"
export PATH="$OECORE_NATIVE_SYSROOT/usr/libexec:$PATH"
export LANG=C.utf8
export LC_ALL=C.utf8

for tool in git make python3 qmake6 rcc; do
  command -v "$tool" >/dev/null || { echo "missing build prerequisite: $tool" >&2; exit 1; }
done
mkdir -p "$root/build"
rm -rf "$output"
git clone --filter=blob:none "$appload_url" "$output/appload"
git -C "$output/appload" checkout --detach "$appload_commit"
git -C "$output/appload" apply --check "$root/patches/appload/0001-root-only-launch-inbox.patch"
git -C "$output/appload" apply "$root/patches/appload/0001-root-only-launch-inbox.patch"
git -C "$output/appload" apply --check "$root/patches/appload/0002-stabilize-launch-model.patch"
git -C "$output/appload" apply "$root/patches/appload/0002-stabilize-launch-model.patch"

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
