# Home Assistant adapter

Paperboard Screen can provide a narrow Home Assistant control surface. The
adapter runs on a trusted host, consumes Screen events, and maps allowlisted
action IDs to predefined Home Assistant service calls.

It never accepts arbitrary entity IDs or service names from a screen message.
Configure mappings in ignored `config/home-assistant.allowlist.local`, then run
the adapter for an already-created Screen session. Safe informational toggles
may execute directly; locks, alarms, covers, and similarly consequential
actions require a Screen confirmation value of `confirmed`.

Use environment variables with the `PAPERBOARD_SCREEN_*` names shown in the
example configuration. Keep Home Assistant and Paperboard tokens in ignored,
mode-0600 files or a secret manager. A dashboard is not automatically a Home
Assistant web dashboard: interactive browser dashboards are too broad for the
tablet security model. Paperboard instead renders explicit agent-controlled
widgets and emits structured events.
