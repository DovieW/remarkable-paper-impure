#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
sdk_root="${REMARKABLE_SDK_ROOT:-$HOME/.local/share/remarkable-sdk/tatsu-3.27.0.97}"

die() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

"$ROOT/scripts/build-paperterm.sh"
bundle="${PAPERTERM_BUILD_DIR:-$ROOT/build/paperterm-tatsu}"
dependency="${PAPERTERM_DEPS_DIR:-$ROOT/build/paperterm-deps/libvterm}"
readelf -h "$bundle/backend/entry" | grep -Fq 'AArch64' || die 'backend is not an AArch64 executable'
node -e 'const m=require(process.argv[1]); if(m.id!=="paperterm" || !m.loadsBackend || m.entry!=="/qml/Main.qml") process.exit(1)' "$bundle/manifest.json"
node -e 'const fs=require("fs"); const b=fs.readFileSync(process.argv[1]); if (b.length < 24 || b.subarray(1,4).toString() !== "PNG" || b.readUInt32BE(16) !== 100 || b.readUInt32BE(20) !== 100) process.exit(1)' "$bundle/icon.png" \
  || die 'PaperTerm AppLoad icon is not a 100x100 PNG'

mapfile -t environment_files < <(find "$sdk_root" -maxdepth 1 -type f -name 'environment-setup-*' -print)
(( ${#environment_files[@]} == 1 )) || die 'Paper Pure SDK is unavailable'
(
  # shellcheck disable=SC1090
  source "${environment_files[0]}"
  export LANG=C.utf8 LC_ALL=C.utf8
qmlformat "$ROOT/src/paperterm/qml/Main.qml" >/dev/null
)
! grep -Fq 'GhostBuster {' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'GhostBuster is an injected context object and must not be instantiated'

gcc -fsyntax-only -std=c11 -O1 -Wall -Wextra -Werror \
  -I"$dependency/include" -I"$dependency/src" $(pkg-config --cflags json-c) \
  "$ROOT/src/paperterm/backend/paperterm-backend.c"

grep -Fq 'PaperTerm must be launched physically' "$ROOT/scripts/install-paperboard-tablet-control.sh"
! grep -Fq 'screenshots are disabled while PaperTerm is open' "$ROOT/scripts/install-paperboard-tablet-control.sh" \
  || die 'PaperTerm screenshots should be available for explicit diagnostics'
grep -Fq 'remote input is disabled while PaperTerm is open' "$ROOT/scripts/install-paperboard-tablet-control.sh"
grep -Fq 'PROFILE_SESSION_WINDOWS_POWERSHELL' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'fixed Windows PowerShell session support is missing'
grep -Fq 'TAILSCALE_PROXY_COMMAND' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'compiled Tailscale proxy support is missing'
grep -Fq -- '--tailscale-proxy-env' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'fixed environment-backed Tailscale proxy entrypoint is missing'
! grep -Fq -- '--tailscale-proxy %h %p' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'Dropbear does not expand OpenSSH proxy placeholders'
grep -Fq 'PROFILE_TAILSCALE_KEY' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'Tailscale key-auth mode is missing'
grep -Fq 'StrictHostKeyChecking=yes' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'strict Tailscale host-key checking is missing'
grep -Fq "p.session === 'windows-powershell'" "$ROOT/scripts/configure-paperterm.sh" \
  || die 'Windows PowerShell session validation is missing'
grep -Fq 'NotoMonoNerdFontMono-Regular.ttf' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'the bundled fixed-width Nerd Font is not loaded'
[[ -s "$bundle/fonts/NotoMonoNerdFontMono-Regular.ttf" ]] \
  || die 'the bundled fixed-width Nerd Font is missing'
printf '%s  %s\n' '7ed8e51bbbc902f537541916f9443630e7781845985f1fbde36aa2db6a4b1c65' \
  "$bundle/fonts/NotoMonoNerdFontMono-Regular.ttf" | sha256sum --check --status \
  || die 'the bundled Nerd Font checksum does not match'
[[ -s "$bundle/LICENSE.nerd-fonts.txt" ]] || die 'the Nerd Fonts OFL license is missing'
grep -Fq 'textFormat: Text.PlainText' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'terminal output must use the responsive plain-text renderer'
! grep -Fq 'snapshot.markup' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'per-cell rich text regressed terminal rendering latency'
grep -Fq 'VTERM_MAX_CHARS_PER_CELL' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'multi-codepoint terminal cells are not preserved'
grep -Fq 'MSG_GET_PROFILES' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'frontend profile refresh request is missing'
grep -Fq 'endpoint.sendMessage(7, "profiles")' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'frontend does not retry profile loading after startup'
! grep -Eq 'sendMessage\([^,]+, ""\)' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'empty AppLoad payloads create zero-length SOCK_SEQPACKET messages and terminate the backend'
[[ "$(grep -Fc 'profilesLoaded = false' "$ROOT/src/paperterm/qml/Main.qml")" == 0 ]] \
  || die 'disconnect/session-end must retain the loaded profiles and avoid retry storms'
grep -Fq 'onClicked: root.disconnectSession()' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'Disconnect must return locally to the profile screen'
grep -Fq 'endpoint.sendMessage(5, "disconnect")' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'Disconnect must use a nonempty AppLoad payload'
grep -Fq 'MSG_SESSION_ENDED' "$ROOT/src/paperterm/backend/paperterm-backend.c" \
  || die 'session teardown is not distinct from application exit'
grep -Fq 'text: "CONNECTING"' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'connection progress state is missing'
grep -Fq 'if (firstFrame) root.fullRefresh()' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'the initial shell frame is not forced onto the e-ink display'
! grep -Fq 'id: connectionRefresh' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'connection progress must not poll the fragile AppLoad socket'
grep -Fq 'height: 54 * unit' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'PaperTerm header should use the compact half-height layout'
! grep -Fq 'Choose a trusted host' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'the profile list should not have an unnecessary title'
! grep -Fq 'Only saved key-based connections appear here' "$ROOT/src/paperterm/qml/Main.qml" \
  || die 'the profile list should not have explanatory subtext'
for key_name in home end pageup pagedown left right up down delete; do
  grep -Fq "action:\"$key_name\"" "$ROOT/src/paperterm/qml/Main.qml" \
    || die "on-screen navigation key is missing: $key_name"
done
bash -n "$ROOT/scripts/authorize-paperterm-key.sh"
printf 'PaperTerm build, backend syntax, QML, manifest, and control-boundary tests passed.\n'
