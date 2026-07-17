# Paperboard v2

Paperboard is a private programmable display for the Paper Pure. One AppLoad
package contains Dashboard, Screen, and Reader modes and shares one transport,
history, chrome behavior, and exit path.

## Behavior

### Dashboard

Dashboard displays queued message, progress, and image cards. Creating or
updating a card is **queue-only**: it must not launch Paperboard or interrupt
the stock notebook, KOReader, or another foreground app. Cards support expiry,
pinning, priorities, and replace keys. Use a replace key for ongoing work so an
agent updates one milestone rather than flooding the queue.

### Screen

Screen is the explicit foreground surface. `screen present` launches the
unified Paperboard package by default and displays structured content. It
supports Markdown-like text, images, continuous one-finger scrolling, history
navigation, choices, confirmations, checklists, single/multi-select controls,
toggles, sliders, HTTPS links, and handwriting.

Pen events preserve normalized vector points and pressure. The relay also
creates a PNG preview for consumers that cannot interpret strokes. The newest
100 displays are retained across sessions. Schema limits keep retained content
well below the 100 MiB safety budget; uploaded assets expire separately.

If Screen remains open for one hour, Paperboard returns to Dashboard. This
avoids leaving a transient agent response on the ambient device indefinitely.

### Reader

Reader is deliberately narrow. It accepts public HTTPS destinations only,
rejects credentials and non-default ports, resolves DNS before connecting,
blocks private/special addresses, validates every redirect, limits response
size/time, and renders extracted text and safe links rather than arbitrary web
scripts. Choose **Browse** from Dashboard, then enter an address or search
phrase with the tablet keyboard. Bare domains are upgraded to HTTPS; other
input is sent to DuckDuckGo Lite search.

Reader keeps the most recent 25 pages in memory for **Back** and **Forward**.
**Reload** re-fetches the current page. **Save** persists a bookmark in the
relay; **Bookmarks** lists the newest 100 saved pages for that tablet. Browser
history is intentionally session-only, while bookmarks survive restarts.
Reader does not execute JavaScript, submit forms, retain cookies, download
files, or attempt to reproduce a full desktop browser.

## On-device controls

- Tap content once to show white-backed top and bottom controls.
- Tap again to hide them.
- Vertical drags scroll Screen content smoothly.
- Reader pages also scroll smoothly; page links are large e-ink-friendly
  targets and browser controls appear in the white bottom bar.
- Horizontal drags navigate Screen history only after gesture direction is
  unambiguous; they do not toggle the controls.
- **Exit** returns to AppLoad/stock UI.

Paperboard performs a full e-ink cleanup refresh when entering an app and after
the configured partial-update threshold. This removes AppLoad ghosting while
avoiding an expensive flash for every small interaction.

## Delivery proof

An API `201` receipt proves that content was accepted by the relay, not that it
was rendered. Receipts contain an operation ID, request ID, device, resource,
cursor, and timestamp. Before telling a user content is visible, compare:

1. the resource cursor;
2. the tablet heartbeat and last acknowledgement cursor;
3. the visible card/session/message fields from device status.

Use `dashboard_wait` or `paperboard dashboard wait` for this distinction.

## Build, deploy, and rollback

```bash
scripts/build-paperboard.sh --clean
scripts/deploy-paperboard.sh --host remarkable-usb --dry-run
scripts/deploy-paperboard.sh --host remarkable-usb
scripts/paperboard-doctor.sh --host remarkable-usb
```

Deployment requires an exact match from `config/compatibility.json`. It stages
the bundle, retains three releases, records two previous deployments, activates
atomically, and rolls back if the package health check fails. It restarts the
Xovi-managed UI services by default so AppLoad loads the new QML resources,
then waits and launches Paperboard. Use `--no-restart-xovi` only for a verified
backend-only release.

```bash
scripts/rollback-paperboard.sh --host remarkable-usb --activate
```

Always back up before deploying. If the tablet is locked, unlock it physically;
the tooling never stores or injects a passcode.

## Configuration

Owner-specific relay URLs and tokens belong under ignored `secrets/` and are
installed as mode-0600 configuration. Never commit or print them. Tablet
configuration is created with `scripts/provision-paperboard-device.sh` and
installed with `scripts/configure-paperboard.sh`.

Provider modes are native, TRMNL Hosted BYOD, and Terminus. Provider traffic is
handled by the relay; credentials do not belong in QML or agent prompts.
