# Paperboard v2 migration

Version 2 intentionally breaks the v1 integration vocabulary while preserving
stored cards, sessions, and events.

| v1 concept | v2 concept |
| --- | --- |
| Paperboard card | Dashboard card |
| Canvas session/message | Screen session/display |
| Tablet control | Device operation |
| `paperboard_*` MCP tools | `dashboard_*` tools |
| `canvas_*` MCP tools | `screen_*` tools |
| `tablet_*` MCP tools | `device_*` tools |
| `cards:*` scopes | `dashboard:*` scopes |
| `canvas:*` scopes | `screen:*` scopes |

The relay applies its SQLite migrations on startup and reports them through
`paperboard admin migrations`. Reissue clients with v2 scopes instead of
editing tokens in place where practical. The admin API can update scopes and
revoke old clients.

The tablet deployment is transactional. A new bundle is staged, verified,
activated, health-checked, and rolled back automatically on failure. The last
three releases and two previous deployment references are retained. Manual
rollback is:

```bash
scripts/rollback-paperboard.sh --host remarkable-usb
```

After verifying v2, remove the old separate Canvas package through AppLoad.
Do not delete relay data merely because internal tables still use the historical
`canvas_` prefix.
