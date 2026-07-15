# Home Assistant adapter

Canvas can act as a deliberately narrow Home Assistant control surface. The
adapter runs on a trusted host, not on the tablet, and consumes Canvas events.
It is disabled until the owner supplies a token file and explicit local
allowlist.

Copy `config/home-assistant.allowlist.example.json` to the ignored
`config/home-assistant.allowlist.local` and map benign Canvas action IDs to one
exact service and entity. Never commit a Home Assistant token.

Risk policy:

- Low: a small set of light, switch, fan, media-player, and input-boolean
  operations can run when explicitly allowlisted.
- Confirmation required: climate, covers, scenes, and vacuums require the
  Canvas event value to be `confirmed`.
- Denied: locks, alarms, cameras, scripts, automations, buttons, unknown
  domains, and unknown services cannot run through this adapter.

Start it only for an already-open Canvas session:

```bash
PAPERBOARD_DEVICE=paper-pure \
CANVAS_SESSION=replace-with-session-id \
HA_URL=https://home-assistant.example.invalid \
HA_TOKEN_FILE=/private/path/home-assistant-token \
HA_ALLOWLIST_FILE=config/home-assistant.allowlist.local \
pnpm home-assistant
```

The relay client token still comes from `PAPERBOARD_TOKEN`. Keep the relay and
Home Assistant endpoints private; do not enable Tailscale Funnel.
