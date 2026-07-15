# Agent tools

Paperboard exposes the same narrow capabilities through a CLI and a local MCP
stdio server. Both call the authenticated relay API; neither can unlock the
tablet, launch apps unexpectedly, or reach arbitrary tablet files.

## CLI

Source one ignored client environment file, then use `pnpm paperboard`:

```bash
set -a; . secrets/clients/local-agent.env; set +a
pnpm paperboard show --device paper-pure --title "Done" --body "The task passed."
pnpm paperboard status --device paper-pure
pnpm paperboard clear --device paper-pure
```

For progress, create a card with a stable replace key. Subsequent `show` calls
using that key replace the previous card; `update --card ID` updates a known
card directly.

## MCP server

Run `pnpm mcp` as a stdio MCP server with `PAPERBOARD_URL` and
`PAPERBOARD_TOKEN` in its process environment. Register this generic command in
any MCP-capable agent:

```json
{
  "command": "pnpm",
  "args": ["--dir", "/absolute/path/to/remarkable", "mcp"],
  "env": {
    "PAPERBOARD_URL": "https://PRIVATE-TAILNET-NAME",
    "PAPERBOARD_TOKEN": "load-this-from-a-secret-manager"
  }
}
```

Do not commit a real hostname or token in an agent configuration. Prefer the
agent's secret store or a private generated config outside the repository.

Available tools:

- `paperboard_show` — queue a message or progress card.
- `paperboard_update` — update an existing card.
- `paperboard_clear` — clear one device queue.
- `paperboard_status` — read queue/cursor/provider/heartbeat state.

## Suggested agent policy

- Use progress cards only for long-running work; update at meaningful
  milestones, not token-by-token.
- Use an urgent final card for a result that needs attention.
- Set a replace key for status streams so retries do not flood the queue.
- Use short TTLs for transient output and pin only information the owner asked
  to retain.
- The relay accepts frequent updates, while the tablet intentionally applies
  at most one visible snapshot every two seconds.
- A successful relay response means queued, not seen. `status` exposes the
  tablet heartbeat and last acknowledged cursor.
