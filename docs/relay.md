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

There are two supported layouts:

- `scripts/deploy-paperboard-relay-truenas.sh` installs the relay as a TrueNAS
  custom app and reuses an existing TrueNAS Tailscale app. This is preferred
  when the NAS is already on the tailnet. It builds on the operator host and
  streams the image directly to TrueNAS; it does not require Docker Hub or
  another registry.
- `deploy/relay/compose.truenas.yml` is the standalone reference stack with a
  dedicated Tailscale container, relay, and Paper Pure Remote.

Both require persistent datasets for relay data and restricted tablet SSH
material. The standalone stack additionally needs Tailscale state and the
Remote kill-switch directory. All owner-specific paths and hostnames belong in
ignored configuration files.

### Existing TrueNAS Tailscale app

Prepare a dedicated dataset once. The example dataset name is not
owner-specific; choose another with `--dataset` if needed.

```bash
ssh USER@NAS \
  'midclt call pool.dataset.create "{\"name\":\"containers/paperboard\",\"type\":\"FILESYSTEM\"}"'
```

Create these paths below its mountpoint:

```text
data/                         UID 100:GID 101, mode 0700
ssh/                          UID 100:GID 101, mode 0700
ssh/config                    UID 100:GID 101, mode 0600
config/tablet-bridge.conf     root:root, mode 0644
secrets/                      root:root, mode 0711
secrets/master_key            root:root, mode 0400
secrets/admin_token           root:root, mode 0400
secrets/tablet_ssh_key        UID 100:GID 101, mode 0400
```

The mixed secret ownership is intentional. The entrypoint reads the master
key and admin token before dropping privileges, then copies the tablet key as
the unprivileged `paperboard` user. Do not loosen these modes to work around a
mount error.

Copy values only from ignored local files, without printing them. Seed
`data/` from a stopped relay container so the SQLite database is consistent,
compare checksums locally, and immediately restart the old relay until the
tablet cutover is complete.

Deploy or update:

```bash
scripts/deploy-paperboard-relay-truenas.sh --host USER@NAS --dry-run
scripts/deploy-paperboard-relay-truenas.sh --host USER@NAS
```

The generated custom-app Compose binds both relay ports to NAS loopback.
Tailscale Serve publishes only the device/client API on private HTTPS port
8787. Port 8788 remains loopback-only, and Funnel must remain disabled. The
script verifies both loopback and tailnet health before succeeding.

After updating the tablet's ignored relay configuration, verify its heartbeat
and acknowledgement cursor before stopping the old relay. Retain the old
volume for rollback until a NAS snapshot and restore check have succeeded.

### Standalone stack

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
