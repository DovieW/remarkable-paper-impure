# TRMNL and Terminus providers

Paperboard supports one optional ambient provider per tablet while direct
agent cards continue to work.

## TRMNL Hosted BYOD

Use this when the owner has a TRMNL Hosted BYOD/Developer API key and wants the
hosted plugin, recipe, playlist, and scheduler ecosystem. The relay calls the
documented `/api/display` endpoint with `ID` and `access-token` headers, fetches
the returned absolute image URL, and normalizes it for Paper Pure.

```bash
set -a; . secrets/clients/local-agent.env; set +a
export PAPERBOARD_ADMIN_TOKEN="$(<secrets/paperboard-admin-token)"
pnpm paperboard provider set --device paper-pure \
  --kind trmnl-hosted --base-url https://trmnl.com \
  --upstream-device EXAMPLE-DEVICE-ID \
  --access-token 'load-from-your-secret-manager'
unset PAPERBOARD_ADMIN_TOKEN
```

Avoid putting real tokens on a command line where shell history or process
inspection can expose them. The explicit command above illustrates fields;
for real setup, use a temporary private shell or a local secret manager.

## Terminus self-hosted

Terminus is TRMNL's flagship BYOS server. It provides its own dashboard,
devices, plugins/extensions, recipes, playlists, scheduler, and APIs. Paperboard
does not replace it; the relay acts as the Paper Pure display client.

The pinned `deploy/terminus/compose.yml` includes Terminus, PostgreSQL, Valkey,
its worker, and a Tailscale Serve sidecar. First check the strict prerequisites:

```bash
scripts/check-paperboard-host.sh
```

Terminus `0.65.0` requires Docker Engine `29.4.2+` and Compose `5.1.2+` in this
deployment. Do not start it on an older host. Initialize persistent secrets,
then edit only the private URL and scoped Tailscale auth key in the ignored
mode-0600 file:

```bash
scripts/init-paperboard-terminus.sh
scripts/start-paperboard-terminus.sh
```

Configure the provider with the private Tailscale HTTPS URL and pass
`--allow-private-http`. The option name reflects the most permissive case, but
it is also the explicit acknowledgement required for any private-address
upstream. The relay is deliberately not joined to Terminus's Docker network,
which keeps its local administration listener isolated from that stack.
Verify that the relay container can resolve and reach both that URL and the
`image_url` Terminus returns; Docker Desktop/WSL tailnet routing can vary. If it
cannot, add a narrowly scoped proxy path rather than joining the two stacks or
exposing the Paperboard admin port.

## Polling semantics

The provider manager checks once per minute. A changed upstream image becomes
one ambient card with a stable replace key; unchanged image hashes are skipped.
Direct cards sort ahead of ambient output. The upstream `refresh_rate` is
currently informational—Paperboard deliberately keeps the one-minute floor.

Switch providers with another `provider set`, or disable ambient output:

```bash
pnpm paperboard provider set --device paper-pure --kind none
```

Provider credentials are encrypted at rest. They never go to the tablet; only
the relay's own device-token-protected normalized image is downloaded there.

Stop without deleting databases or uploads:

```bash
scripts/stop-paperboard-terminus.sh
```
