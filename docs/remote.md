# Paper Pure Remote

Paper Pure Remote is a lightweight, local browser viewer for an unlocked
reMarkable Paper Pure. It repeatedly captures the physical display over the
pinned SSH connection and maps browser clicks and drags to the repository's
reviewed tap and swipe helper.

It is intentionally closer to a slow, safe remote control than a video stream.
The current full-frame screenshot path normally updates in roughly one to
three seconds. It is useful for navigating applications, validating UI work, and
reducing physical handoffs; it is not fast enough for live handwriting.

## Start it

Connect the tablet over USB or another already-pinned SSH route, physically
unlock it, and run:

```bash
scripts/start-paper-remote.sh
```

Open <http://127.0.0.1:4174> on the same computer. To choose another local
port or existing SSH alias:

```bash
PAPER_REMOTE_PORT=4175 REMARKABLE_HOST=remarkable-wifi scripts/start-paper-remote.sh
```

The launcher validates the observed platform as `imx93-tatsu`, architecture as
`aarch64`, screenshot broker, and installed input helper before starting.

## Controls

- **Refresh now** requests a fresh screenshot immediately.
- **Rotate 90 degrees** rotates both the image and input-coordinate mapping.
- **Cadence** controls the delay before the next capture. Captures never
  overlap, so a slow tablet cannot create an unbounded queue.
- **Paperboard**, **Canvas**, and **Exit custom app** use fixed, reviewed
  AppLoad actions. They cannot accept a command or arbitrary application ID.
- A click becomes a tap. A drag becomes a bounded swipe whose duration follows
  the browser gesture.

Input begins disarmed. Before arming it, the owner must confirm that the tablet
is already physically unlocked. Arming expires after five minutes, and Exit
disarms immediately. The remote does not support text entry, passcode storage,
unlocking, shell commands, recovery operations, or arbitrary tablet paths.

## Security and privacy boundary

The HTTP server always binds to host loopback at `127.0.0.1`; it has no option
to bind to the LAN or tailnet. A random process-local token protects every
screenshot and control endpoint, browser caching is disabled, and restrictive
browser headers prevent framing or cross-origin scripts. Screenshots use a
mode-private temporary directory and are deleted immediately after each HTTP
response is prepared.

No service or listening port is installed on the tablet. Each action travels
through key-authenticated SSH. While the local viewer is running, one SSH child
holds an idle `/dev/uinput` touchscreen so Qt pays its device-discovery cost
only once. The helper accepts only validated `tap` and `swipe` records. Closing
the viewer closes SSH input, destroys the touchscreen, and leaves no persistent
remote-control daemon.

The screenshot can contain personal documents. Do not share browser captures
or expose the local server through a reverse proxy, Tailscale Serve, Funnel,
port forwarding, or a container published on `0.0.0.0`.

## Stop, disable, and remove

Press `Ctrl+C` in the starting terminal. This closes the local listener,
deletes its temporary directory, and leaves no tablet process to uninstall.
For a clean handoff, disarm input first and use **Exit custom app** if desired.

Updating the input helper keeps its preceding binary at
`/home/root/.local/bin/paperctl-tap.previous`. If the optimized helper fails,
stop the viewer and restore that file over `paperctl-tap` through the pinned
USB SSH connection, then verify `scripts/paperctl.sh status`. This rollback
does not touch the stock UI, documents, boot partitions, or recovery system.

Removing Paper Pure Remote itself requires only deleting `apps/remote`, this
document, `scripts/start-paper-remote.sh`, and the root package script. Do not
remove `paperctl-tap` solely to remove the viewer: it is also the reviewed
developer diagnostic input helper documented in
[Agent autonomy](agent-autonomy.md).

## Troubleshooting

- **Capture unavailable:** confirm the tablet is awake and unlocked, then run
  `scripts/paperctl.sh status`.
- **Input disarmed:** unlock physically and arm again. Never use the viewer to
  enter the passcode.
- **Image is sideways:** use Rotate; input mapping rotates with it.
- **Frames feel slow:** full PNG capture is currently the dominant delay. A
  future incremental framebuffer stream can improve it without changing the
  HTTP security boundary.
- **Port already used:** set `PAPER_REMOTE_PORT` to another loopback port.
