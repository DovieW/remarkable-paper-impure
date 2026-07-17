# Agent CLI and MCP tools

The CLI, MCP server, client library, and HTTP API share the v2 operation
registry in `packages/core/src/operations.ts`. Public names are grouped by
intent: `dashboard`, `screen`, and `device`. Admin operations remain a separate
loopback-only control plane and are intentionally CLI-only.

## Meaning of common words

- **dashboard** means queued ambient content. It never foregrounds an app.
- **screen** means interactive content in Paperboard Screen. Presenting it
  foregrounds Paperboard unless `foreground=false` is explicit.
- **device** means observable tablet state or a bounded semantic operation.
- **screenshot** reports what the unlocked user can currently see; it is not a
  synonym for screen.

## CLI

Install/build the workspace, source an ignored client environment in a
subshell, and invoke `pnpm paperboard -- ...` or the built CLI:

```bash
paperboard dashboard show --device DEVICE --title "Build" --body "Running" --replace-key build
paperboard dashboard wait --device DEVICE --card CARD --until acknowledged
paperboard screen start --device DEVICE --title "Review"
paperboard screen present --device DEVICE --session SESSION --title "Choose" --actions '[{"type":"choice","id":"accept","label":"Accept"}]'
paperboard device status --device DEVICE
paperboard device screenshot --device DEVICE --output /tmp/tablet.png
```

Complete namespaces:

```text
dashboard asset upload
dashboard show | update | list | get | delete | clear | wait
screen start | present | list | status | events | ack | close
device status | apps | launch | exit | screenshot | control | command-status
admin device create | device rotate-token
admin client create | client list | client scopes | client revoke
admin provider set | migrations
```

Commands return JSON receipts/status. Tokens are supplied through environment
variables or ignored files, never command arguments that leak into process
lists.

## MCP

The MCP server exposes the equivalent public tools:

```text
dashboard_asset_upload  dashboard_show       dashboard_update
dashboard_show_image    dashboard_list       dashboard_get
dashboard_delete        dashboard_clear      dashboard_wait
screen_start            screen_present       screen_list
screen_status           screen_events        screen_ack
screen_close            device_status        device_apps
device_launch           device_exit          device_screenshot
device_control          device_command_status
```

Configure a default device in the MCP process environment so an agent does not
need owner-specific identifiers in prompts. MCP config contains an executable
and ignored environment-file path, not the token itself.

## Agent protocol

1. Use Dashboard for ambient/status requests and a replace key for progress.
2. Use Screen when the human asks to show, choose, confirm, draw, or interact.
3. Read the structured receipt.
4. Check status/acknowledgement before claiming delivery or visibility.
5. For Screen, consume events after a cursor, act once, then acknowledge them.
6. Use only semantic device actions. Never automate unlock or arbitrary shell.

The relay enforces per-client scopes. Give an integration only the scopes it
needs; `scripts/provision-paperboard-client.sh` creates a full v2 client for
trusted agents, while the admin API can later narrow or revoke it.
