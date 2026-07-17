# Canvas migration notice

Paperboard Canvas was merged into **Paperboard Screen** in v2. It is no longer
a separate AppLoad application or public API namespace.

- Say **dashboard** for queued ambient cards.
- Say **screen** for interactive foreground content.
- Use `screen_*` MCP tools or `paperboard screen ...` CLI commands.

Existing v1 database tables retain `canvas_` names internally so migrations are
non-destructive. Those names are not part of the v2 contract. See
[v2 migration](v2-migration.md) and [Paperboard](paperboard.md).
