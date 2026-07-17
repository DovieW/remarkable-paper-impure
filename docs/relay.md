# Paperboard relay

The relay is the private control/data plane between agents, providers, and the
tablet. It exposes the versioned client API on private-tailnet HTTPS, a device
poll API authenticated by a device token, and an admin API on host loopback.

## Components

- SQLite stores cards, Screen sessions/events, cursors, audits, clients, and
  migrations.
- Assets are normalized and expire on a bounded schedule.
- A tablet bridge performs allowlisted SSH status, launch, exit, screenshot,
  and semantic command operations.
- TRMNL Hosted BYOD and Terminus adapters map provider frames into Dashboard
  cards.
- Tailscale Serve terminates private HTTPS. Funnel must remain disabled.

## TrueNAS Scale

Use `deploy/relay/compose.truenas.yml`. Persistent datasets are required for
relay data, Tailscale state, restricted tablet SSH material, and the Remote
kill-switch directory. All owner-specific paths/hostnames live in ignored
`.env` files.

The compose stack:

- pins the Tailscale image digest;
- shares only Tailscale's network namespace;
- mounts secrets as files;
- keeps admin on `127.0.0.1:8788`;
- runs relay read-only with dropped capabilities;
- serves Remote under `/remote/` and relay at `/`.

Validate before starting:

```bash
docker compose --env-file deploy/relay/.env \
  -f deploy/relay/compose.truenas.yml config --quiet
```

Provision through an SSH tunnel to the admin listener, never by publishing the
admin port. `scripts/provision-paperboard-device.sh` creates one device and a
v2 client, writing credentials only to ignored mode-0600 files.

## Migration and audit

The relay applies migrations at startup. Inspect them with:

```bash
paperboard admin migrations
paperboard admin client list
```

Revoke legacy or unused clients after issuing v2 scopes. Audit records capture
mutating operation, client, device, resource, request ID, and timestamp without
storing bearer tokens.

## Backups

Use filesystem/ZFS snapshots of the persistent dataset. Do not add a second
application-specific backup format. Snapshot before upgrading, retain according
to the NAS policy, and test restoration into a separate path/container.

## Health

- relay HTTP health and private HTTPS reachability;
- device heartbeat and acknowledgement cursor;
- tablet bridge SSH status;
- migration list;
- Remote `/api/session` health;
- `scripts/paperboard-doctor.sh` from a trusted operator host.

A queued receipt is not proof of tablet display. Use status cursor/heartbeat
and last acknowledgement before reporting successful delivery.
