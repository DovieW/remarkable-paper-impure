# Paperboard relay

## TrueNAS always-on deployment

`deploy/relay/compose.truenas.yml` moves the existing relay identity and durable
state to a TrueNAS custom app. Stop the WSL relay before copying its SQLite
database, assets, master key, client/device token state, and Tailscale state.
Verify archive checksums before starting the TrueNAS app and retain the stopped
WSL volumes until rollback is no longer needed.

The public tailnet HTTPS listener proxies only the client API. The admin
listener remains on container loopback. The optional tablet bridge is part of
the relay process but uses a forced-command SSH key that rejects arbitrary
shell commands, paths, taps, and passcodes. Screenshot output is streamed from
the tablet and never written by the relay.

For the Windows/WSL deployment, that key is mounted as a Docker secret. The
container entrypoint copies it into tmpfs with mode 0600 before dropping
privileges. The mounted SSH configuration pins the host key learned over
physical USB; the bridge accepts only status, installed-app enumeration,
explicit AppLoad launch/return, and one ephemeral screenshot operation.

Do not start the TrueNAS deployment with a new Tailscale identity while the old
relay is still active under the same hostname.

The relay is a small Node.js 24 service backed by SQLite. It stores only the
current queue, normalized image assets, hashed tokens, encrypted provider
configuration, idempotency responses, and body-free delivery events.

## WSL host with Windows already on the tailnet

This is the simplest path when Windows Tailscale is already running:

```bash
pnpm install --frozen-lockfile
scripts/check-paperboard-host.sh
scripts/init-paperboard-relay.sh
```

Edit ignored `deploy/relay/.env` locally. Set the private HTTPS address that
Windows Tailscale Serve will provide. Do not commit or paste that hostname or
the contents of `secrets/`.

```bash
scripts/start-paperboard-relay-windows.sh
curl --fail http://127.0.0.1:8787/healthz
```

The script starts the relay in WSL, bound to Windows loopback, and asks the
installed Windows Tailscale CLI to Serve it over private tailnet HTTPS. It does
not enable Funnel or public ingress.

## Portable container-side Tailscale

On a Linux host where the relay should own its tailnet node:

```bash
scripts/start-paperboard-relay.sh
```

The portable Compose stack shares the Tailscale sidecar's userspace network
namespace. Use a tagged, reusable auth key and tailnet policy appropriate to
the deployment.

## Provision identities

The admin listener is loopback-only on port `8788`; it is intentionally absent
from the tailnet listener.

```bash
scripts/provision-paperboard-device.sh \
  --device paper-pure --client local-agent
```

To add another least-privilege agent without rotating or reprovisioning the
tablet identity:

```bash
scripts/provision-paperboard-client.sh \
  --client example-agent --device paper-pure
```

Device and agent tokens are different. Tokens are shown only once to the
provisioning script, written to ignored mode-0600 files, and stored in SQLite
only as SHA-256 hashes. Rotate a tablet token with the admin CLI and reinstall
its config if compromise is suspected.

## Persistence and retention

- SQLite uses WAL mode in the `relay-data` volume.
- Unpinned cards expire after their TTL; default five minutes, maximum 24h.
- Normalized image assets expire after 24h.
- Idempotency responses expire after one day.
- Delivery records contain device, cursor, action, and timestamp only; no card
  title/body. They expire after seven days.
- Provider credentials are AES-256-GCM encrypted using the separate master key
  mounted at runtime.

Back up the Docker volume and both secret files together if relay recovery is
required. A database without the master key cannot decrypt provider config.

## Container boundary

The relay runs read-only, with a small tmpfs, `no-new-privileges`, and all
capabilities dropped. A tiny entrypoint uses only `SETUID`/`SETGID` to read
group-only Docker secrets, then PID 1 becomes an unprivileged Node process with
no effective capabilities. The admin API is a separate local listener.
