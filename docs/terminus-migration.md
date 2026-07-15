# Terminus backup and migration

Terminus is portable, but it is stateful. Move the database and uploaded
screens together, preserve the application secrets, and keep the old instance
stopped until the new one has passed its display test.

This runbook covers migration between the repository's WSL Compose deployment
and a private TrueNAS SCALE Custom App. It intentionally does not contain a
tailnet hostname, credentials, device identifiers, database passwords, or
volume names from a particular installation.

## What must move

- The PostgreSQL database, including users, devices, models, screens,
  playlists, extensions, and scheduler state.
- The Terminus upload volume containing rendered screen assets.
- The persistent Terminus application secret and database credentials.
- The private `TERMINUS_PUBLIC_URL` setting appropriate for the destination.

Valkey is transient queue/cache state and does not need to be migrated. Stop
the worker and web service before the final database and upload backup so the
two copies describe one point in time.

## Before migration

1. Record the running Terminus image tag. Do not combine a host move with a
   Terminus upgrade.
2. Confirm a recent database dump can be listed or restored in a disposable
   PostgreSQL instance of the same major version.
3. Confirm the upload archive contains the rendered files referenced by the
   database.
4. Copy the backup to an encrypted, access-controlled destination outside this
   public repository.
5. Keep the old deployment and its volumes intact for rollback.

## WSL Compose source

The local deployment uses the named volumes declared in
`deploy/terminus/compose.local.yml`. Discover the generated container and
volume names from Compose rather than assuming them:

```bash
docker compose --env-file deploy/terminus/.env \
  -f deploy/terminus/compose.local.yml ps
docker compose --env-file deploy/terminus/.env \
  -f deploy/terminus/compose.local.yml config --volumes
```

Stop incoming display requests, then stop the web and worker services. Create
a custom-format `pg_dump` from the database container and archive the upload
volume with ownership and permissions preserved. Do not place either artifact
inside this repository. The exact container and volume names are local values
and belong in `PERSONAL.md` or the private backup log.

Restart the old stack if migration is not happening immediately:

```bash
scripts/start-paperboard-terminus-local.sh
```

## TrueNAS SCALE source or destination

Use protected datasets for PostgreSQL and uploads when defining the Custom
App. Snapshot both datasets after stopping the Terminus web and worker
containers. Replicate those snapshots together, or create a database dump and
an upload archive as described above.

Do not expose PostgreSQL, Valkey, or the Terminus administration listener.
Keep Terminus on host loopback and publish only a private Tailscale Serve HTTPS
listener. Funnel remains disabled.

When restoring to TrueNAS:

1. Create the destination datasets and apply the container ownership expected
   by the pinned image.
2. Restore uploads and the PostgreSQL dump while Terminus web and worker are
   stopped.
3. Configure the same application secret and database credentials through the
   TrueNAS secret/configuration boundary.
4. Set `TERMINUS_PUBLIC_URL` to the destination's private HTTPS Serve URL.
5. Start database and Valkey, then web, then worker.

## Cutover verification

Verify in this order:

1. Terminus `/up` succeeds through private tailnet HTTPS.
2. The administrator UI contains the expected model, playlist, screens, and
   virtual device.
3. `/api/display` returns an image URL reachable from the Paperboard relay.
4. Restart the relay once to force an immediate provider check.
5. Confirm the Paperboard cursor advances while the tablet remains in the
   stock UI.
6. Open Paperboard manually and visually confirm the ambient screen.
7. Use RETURN and verify the tablet backend stops.

Only after those checks should DNS/Serve names or the Paperboard provider
configuration be switched permanently. Retain the old deployment until at
least one complete backup cycle has succeeded on the destination.

## Rollback

Stop the new web and worker services, restore the old private URL/provider
configuration, and restart the old deployment without modifying its retained
volumes. A failed migration should not require rebuilding screens or pairing a
new virtual device.
