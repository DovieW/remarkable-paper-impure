# TRMNL and Terminus providers

Paperboard supports one optional ambient provider per tablet while direct
agent cards continue to work.

## TRMNL Hosted BYOD

Use this when the owner has a TRMNL Hosted BYOD/Developer API key and wants the
hosted plugin, recipe, playlist, and scheduler ecosystem. The relay calls the
documented `/api/display` endpoint with `ID` and `access-token` headers, fetches
the returned absolute image URL, and normalizes it for Paper Pure.

In the TRMNL web app, open the BYOD device's settings and copy its device ID
and Device API Key. Keep both values out of chat and command-line arguments.
Run the local helper and enter both values at its hidden local prompts:

```bash
scripts/configure-paperboard-trmnl-hosted.sh
```

The helper puts the key in a mode-0600 temporary file, sends it through the
loopback-only Paperboard admin API, and deletes the file. The relay encrypts
the provider configuration at rest. For non-interactive secret-manager use,
the underlying CLI accepts `--access-token-file`.

## Terminus self-hosted

Terminus is TRMNL's flagship BYOS server. It provides its own dashboard,
devices, plugins/extensions, recipes, playlists, scheduler, and APIs. Paperboard
does not replace it; the relay acts as the Paper Pure display client.

The pinned `deploy/terminus/compose.yml` includes Terminus, PostgreSQL, Valkey,
its worker, and a Tailscale Serve sidecar. First validate the local Docker
daemon and the deployment features this repository actually uses:

```bash
scripts/check-paperboard-host.sh
```

Terminus does not publish a minimum Docker Engine or Compose version. The check
above therefore tests capabilities and parses both Compose definitions instead
of imposing an invented version floor. Initialize persistent secrets, then
edit only the private URL and scoped Tailscale auth key in the ignored
mode-0600 file:

```bash
scripts/init-paperboard-terminus.sh
scripts/start-paperboard-terminus.sh
```

For an initial test on the WSL host, keep Terminus on host loopback and avoid a
second tailnet node entirely:

```bash
scripts/init-paperboard-terminus.sh
scripts/start-paperboard-terminus-local.sh
```

Open `http://localhost:2300`, register the first local administrator, create a
virtual device and screen, then configure Paperboard without putting its local
device identifier in shell history or chat:

```bash
scripts/configure-paperboard-terminus-local.sh
```

The local stack publishes only the web service on `127.0.0.1`; PostgreSQL and
Valkey remain on its private Docker network. Its named volumes are retained by
`scripts/stop-paperboard-terminus-local.sh`, making later backup and migration
to another WSL or TrueNAS SCALE host possible.

### TrueNAS SCALE with an existing tailnet node

When TrueNAS already runs Tailscale, use the same topology as the local stack:

1. Deploy `deploy/terminus/compose.local.yml` as a TrueNAS Custom App, retaining
   its named volumes or mapping them to protected datasets.
2. Keep Terminus bound to host loopback on port `2300`; do not publish its
   database or Valkey services.
3. Add a private Tailscale Serve listener that proxies to
   `http://127.0.0.1:2300`. Keep Funnel disabled.
4. Set `TERMINUS_PUBLIC_URL` to that private HTTPS Serve URL, then verify both
   `/up` and `/api/display` through the tailnet before configuring Paperboard.

This avoids creating a second Tailscale identity beside the TrueNAS host and
keeps Terminus administration private. Enter persistent application/database
secrets through the TrueNAS secret/configuration boundary; do not paste them
into chat or commit a rendered compose file. Back up the database and upload
volumes together before moving the app to another host.

### Add the Paper Pure model

For an initial hands-on setup, create the model in the Terminus UI. The tracked
browser helper fills the reusable, non-secret Paper Pure rendering values but
deliberately leaves the final Save action to the operator:

```bash
clip.exe < tools/terminus/fill-paper-pure-model.js
```

Open **Models -> New**, open the browser developer console, paste the helper,
and run it. Review the highlighted form before clicking **Save**. The helper
uses the Paper Pure's native `1872x1404` landscape space, 16 grayscale levels,
and no rotation. It selects the 16-gray palette when Terminus has synchronized
that palette; otherwise it leaves the palette unchanged and reports the omission.
It does not contain credentials or owner-specific values, so it belongs in the
repository rather than an ignored temporary-scripts directory.

The repository also includes a reusable landscape operations screen at
`tools/terminus/paperboard-operations.html`. Create an HTML screen for the
Paper Pure model, paste that file as its content, and add it to an automatic
playlist. A 60-second device refresh rate matches Paperboard's provider floor;
shorter Terminus values do not make Paperboard poll faster.

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

## Verified Terminus path

Terminus `0.65.0` was exercised as a TrueNAS SCALE Custom App behind private
Tailscale Serve. The relay fetched its advertised display image, normalized it,
the Paper Pure acknowledged the resulting cursor, and a direct urgent agent
card continued to render alongside the ambient card. No public listener or
Funnel was used.

Stop without deleting databases or uploads:

```bash
scripts/stop-paperboard-terminus.sh
```

See [Terminus backup and migration](terminus-migration.md) before moving the
deployment between WSL and TrueNAS SCALE.
