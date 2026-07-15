# Canvas

Canvas is the interactive companion to Paperboard. Paperboard remains a quiet,
queue-oriented ambient display. Canvas is opened manually from AppLoad when a
person wants a short touch conversation with an agent or automation.

## Interaction model

An agent opens a session, sends messages, and attaches structured actions. The
tablet returns choice, confirmation, or checklist events. The agent reads and
acknowledges those events through the same authenticated client API, CLI, or MCP
surface. V1 intentionally has no on-screen keyboard and does not attempt
handwriting recognition.

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

Canvas reuses Paperboard's reviewed TLS-authenticated device transport and
private device configuration. Deployment is constrained to the observed Paper
Pure platform and OS 3.27.x. It never launches itself or steals focus. Reload
AppLoad, then open Canvas manually.

If Canvas misbehaves, return to AppLoad and remove only
`/home/root/xovi/exthome/appload/canvas`. This does not touch Paperboard, the
stock UI, user documents, boot, or recovery partitions.
