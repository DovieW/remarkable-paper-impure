# Paperboard Canvas

Paperboard Canvas is the interactive companion to Paperboard. Paperboard remains a quiet,
queue-oriented ambient display. Canvas is opened manually from AppLoad when a
person wants a short touch conversation with an agent or automation.

## Interaction model

An agent opens a session, sends messages, and attaches structured actions. The
tablet returns choice, confirmation, or checklist events. The agent reads and
acknowledges those events through the same authenticated client API, CLI, or MCP
surface. V1 intentionally has no on-screen keyboard and does not attempt
handwriting recognition.

Canvas stores the newest 100 displays across sessions. Previous and next
navigation therefore survives agents opening a fresh session for later work;
replace-key updates remain replacements so progress ticks do not flood history.
Text history is small (at most roughly 1.2 MB when every body reaches the
12 KB limit), while image assets retain their separate expiration policy.

The white-backed header and footer begin hidden and overlay rather than consume
content space. Tap the reading surface to reveal them and tap the surface again
to dismiss them; they also hide automatically after six seconds. The footer
provides previous, next, return-to-top, refresh, and Exit controls. Horizontal
swipes also move through history and require a clearly dominant horizontal
gesture so ordinary vertical reading does not navigate accidentally.

Canvas is deliberately temporary foreground UI. One hour after it opens, it
launches Paperboard and closes itself so an abandoned interactive screen returns
to the quiet dashboard automatically.

The message body and actions use one-finger kinetic vertical scrolling without
page snapping. A slim position marker appears only when content overflows. New
messages and explicit history navigation start at the top.

The session title appears only in the optional header, while each message title
is the visible content heading. Agents should not repeat that message title as
the first Markdown heading in the body; doing so intentionally renders two
matching content headings.

```bash
set -a; . secrets/clients/local-agent.env; set +a
session=$(pnpm paperboard canvas start --device paper-pure --title "Dinner" | jq -r .id)
pnpm paperboard canvas send --device paper-pure --session "$session" \
  --title "Choose dinner" --body "What sounds good?" \
  --actions '[{"type":"choice","id":"pizza123","label":"Pizza"}]'
pnpm paperboard canvas events --device paper-pure --session "$session"
```

Source ignored secret files in a subshell in automation so tokens do not leak
into the parent environment.

## Build and lifecycle

```bash
scripts/build-canvas.sh --clean
scripts/deploy-canvas.sh --dry-run
scripts/deploy-canvas.sh
```

Paperboard Canvas reuses Paperboard's reviewed TLS-authenticated device transport and
private device configuration. Deployment is constrained to the observed Paper
Pure platform and OS 3.27.x. It never launches itself or steals focus. Reload
AppLoad, then open Canvas manually.

If Paperboard Canvas misbehaves, return to AppLoad and remove only
`/home/root/xovi/exthome/appload/canvas`. This does not touch Paperboard, the
stock UI, user documents, boot, or recovery partitions.
