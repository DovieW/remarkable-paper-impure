# Paper Pure Remote

Paper Pure Remote is an ephemeral browser view of the unlocked tablet. It uses
a restricted SSH forced-command key for capture, bounded tap/swipe input, and
three semantic controls:
Dashboard, Screen, and Exit.

It does **not** implement passcode entry, keyboard/text injection, arbitrary
commands, or a persistent screenshot archive.

## Local development

```bash
scripts/start-paper-remote.sh --host remarkable-usb
```

The local server binds to `127.0.0.1`. Open the printed loopback URL. Each page
load receives a random in-memory session token. Input is rejected unless the
server was explicitly started with input enabled and the kill-switch file is
absent.

The UI shows a tap immediately, expects the SSH input acknowledgement within
250 ms on a warm connection, then refreshes at roughly 100 ms and 700 ms. A
full visible e-ink update normally appears within 1–2 seconds; the selectable
500/1500/5000 ms polling cadence controls continued capture.

## TrueNAS/tailnet deployment

The preferred custom-app deployment in
`deploy/relay/compose.truenas-app.yml` runs Remote beside Relay, binds both to
NAS loopback, and reuses the existing NAS Tailscale app. The standalone
`deploy/relay/compose.truenas.yml` remains available when a dedicated Tailscale
container is required. Both publish Remote at:

```text
https://PRIVATE-TAILNET-NAME/remote/
```

Access is authenticated by the tailnet and restricted by its ACL/tag policy.
There is no second application password in this topology. This is safe only if
the ACL admits the intended personal devices and no Funnel/public exposure is
enabled.

Set in the ignored deployment environment:

```text
PAPER_REMOTE_INPUT_ENABLED=true
PAPERBOARD_REMOTE_CONTROL_DIR=/mnt/POOL/paperboard/remote-control
```

The lifecycle manager creates `remote.disabled` by default. For an attended
session, use the reviewed controls rather than editing the dataset manually:

```bash
scripts/manage-paperboard-truenas.sh remote-arm --host USER@NAS --confirm
scripts/manage-paperboard-truenas.sh remote-disarm --host USER@NAS
```

The app also rate-limits input to eight requests
per second, validates coordinates/duration, and limits request bodies.

## Wi-Fi changes

The SSH alias mounted into the container should target a stable Tailscale or
bridge hostname, not a transient LAN address. A Tailscale endpoint survives
hotspot/LAN changes after both endpoints reconnect. The tablet still must be
awake, unlocked, connected, and running its tunnel/SSH service. Remote cannot
cross the physical unlock boundary.

## Troubleshooting

- **Capture unavailable:** verify the tablet is awake/unlocked and run
  `scripts/paperboard-doctor.sh` from the trusted host.
- **Input disabled:** inspect the server policy and kill-switch file.
- **404 under `/remote/`:** confirm `PAPER_REMOTE_BASE_PATH=/remote` and the
  Tailscale Serve handler.
- **Slow visual result:** distinguish fast input acknowledgement from the
  tablet's e-ink refresh and screenshot capture.
