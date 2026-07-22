#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf 'test-chat.sh: %s\n' "$*" >&2; exit 1; }

"$ROOT/scripts/build-chat.sh" --clean
qml="$ROOT/src/chat/qml/Main.qml"
keyboard="$ROOT/src/shared/qml/OnScreenKeyboard.qml"

grep -Fq 'listMode: "inbox"' "$qml" || die 'Inbox view is missing'
grep -Fq '["INBOX","ARCHIVED","REMOVED","SEARCH","NEW"]' "$qml" || die 'conversation list navigation is incomplete'
grep -Fq 'text:"RESTORE"' "$qml" || die 'secondary conversation views lack Restore'
! grep -Fq 'HIDDEN' "$qml" || die 'the unclear Hidden label remains in Chat'
grep -Fq 'root.contextualActions()' "$qml" || die 'conversation controls are not state-aware'
grep -Fq 'resultStrip' "$qml" || die 'persistent action feedback is missing'
grep -Fq 'pendingActionId.length' "$qml" || die 'repeat taps are not suppressed while an action is pending'
grep -Fq 'kind:"regenerate"' "$qml" || die 'Regenerate is not distinct from Retry'
grep -Fq 'lastUserMessage("failed")' "$qml" || die 'Retry is not limited to failed user messages'
grep -Fq 'OnScreenKeyboard' "$qml" || die 'Chat is not using the shared keyboard'
grep -Fq 'terminalMode:false' "$qml" || die 'Chat keyboard is not in text-entry mode'
grep -Fq 'signal submitRequested' "$keyboard" || die 'shared keyboard has no explicit Send action'
grep -Fq 'signal macroRequested' "$keyboard" || die 'shared keyboard no longer supports PaperTerm macros'
grep -Fq 'alias="qml/OnScreenKeyboard.qml"' "$ROOT/src/chat/application.qrc" || die 'shared keyboard is absent from the Chat resource bundle'

printf 'Chat build, navigation, feedback, and shared-keyboard tests passed.\n'
