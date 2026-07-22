#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pnpm --dir "$ROOT/integrations/openclaw-paperchat" build
test -s "$ROOT/integrations/openclaw-paperchat/dist/index.js"
sha256sum "$ROOT/integrations/openclaw-paperchat/dist/index.js" > "$ROOT/integrations/openclaw-paperchat/dist/index.js.sha256"
printf 'OpenClaw PaperChat plugin built: %s\n' "$ROOT/integrations/openclaw-paperchat/dist/index.js"
