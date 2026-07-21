# Paper Pure developer starter kit

An agent-first toolkit for safely turning a **reMarkable Paper Pure** in
Developer Mode into a backed-up, recoverable development device. It preserves
the stock notebook experience while adding reproducible SSH access, custom
applications, a private programmable display, and narrow remote operations.

> [!WARNING]
> Developer Mode weakens the tablet security posture and may factory-reset it.
> Do not put enterprise or confidential work data on a modified tablet without
> explicit organizational approval.

## Hand this repository to an AI agent

Clone it in WSL or Linux, open the folder, and say:

> Read `AGENTS.md` completely. Bring my Paper Pure from zero to safe,
> key-authenticated SSH access. Stop at physical and password boundaries,
> identify and back up the device before writes, and keep personal values out
> of Git.

The binding agent contract is [AGENTS.md](AGENTS.md). The owner walkthrough is
[docs/agent-quickstart.md](docs/agent-quickstart.md). Local device details live
only in ignored `PERSONAL.md`, created from `PERSONAL.example.md`.

## Safe order

1. Sync or back up documents before enabling Developer Mode.
2. Connect by USB and run `scripts/bootstrap-ssh.sh` in the owner's terminal.
3. Identify the tablet with `scripts/status.sh --host remarkable-usb`.
4. Back up with `scripts/backup.sh --host remarkable-usb` and verify checksums.
5. Read [docs/recovery.md](docs/recovery.md) before modifying the device.
6. Add one reversible capability at a time.

The exact supported custom-app baseline is machine-readable in
[`config/compatibility.json`](config/compatibility.json). Deployment fails
closed when the observed platform, architecture, or OS is not approved.

## Paperboard v2

Paperboard v2 is one tablet application with three modes:

- **Dashboard** is a quiet queue of cards. Posting never steals focus.
- **Screen** is agent-presented, interactive content. Presenting foregrounds
  Paperboard by default and supports choices, confirmations, checklists,
  toggles, selections, sliders, links, images, and pen strokes.
- **Reader** is a lightweight, script-free browser for constrained public HTTPS
  pages. It accepts addresses or searches, exposes safe page links, keeps 25
  pages of in-session back/forward history, and persists up to 100 bookmarks.
  Private, loopback, link-local, credential-bearing, and unsafe redirects are
  blocked.

Tap once to show the white top and bottom controls and tap again to hide them.
Screen content scrolls continuously. The latest 100 displays are retained;
after one hour Screen returns to Dashboard. The old separate Canvas app and
v1 names are retired—see [docs/v2-migration.md](docs/v2-migration.md).

Every integration uses the same v2 operation vocabulary:

```text
dashboard show|update|list|get|delete|clear|wait
screen start|present|list|status|events|ack|close
device status|apps|launch|exit|screenshot|control|command-status
admin device|client|provider|migrations
```

See [docs/agent-tools.md](docs/agent-tools.md) for CLI and MCP use, and
[docs/paperboard.md](docs/paperboard.md) for the application behavior.

PaperTerm is the separate, physical-user-only terminal application. It opens
saved Tailscale SSH or key-based SSH sessions without adding an interpreter or
web terminal to the tablet. Remote launch, screenshots, and injected input are
blocked while it is open. See [docs/paperterm.md](docs/paperterm.md).

## Relay and remote

The relay supports native Paperboard clients, TRMNL Hosted BYOD, and self-hosted
Terminus. The preferred TrueNAS custom app includes both Relay and Paper Pure
Remote, reuses the NAS Tailscale app, and keeps every admin listener on host
loopback. [docs/relay.md](docs/relay.md) covers deployment and lifecycle.

Paper Pure Remote provides an ephemeral browser mirror with bounded tap/swipe
input. It never automates unlock, accepts text, or exposes arbitrary shell.
The TrueNAS deployment serves it under `/remote/` only to devices permitted by
the tailnet ACL; an on-disk kill switch still disables input immediately. See
[docs/remote.md](docs/remote.md).

The lifecycle entrypoint is intentionally explicit about the NAS SSH target:

```bash
scripts/manage-paperboard-truenas.sh status --host USER@NAS
scripts/manage-paperboard-truenas.sh snapshot --host USER@NAS
scripts/manage-paperboard-truenas.sh deploy --host USER@NAS
```

Owner-specific aliases and paths belong in ignored configuration, never in
tracked examples.

## Development and release checks

```bash
pnpm install --frozen-lockfile
scripts/remarkable check host
scripts/remarkable check release
```

The command center also exposes the routine device and application workflows:

```bash
scripts/remarkable status --host remarkable-usb
scripts/remarkable smoke-test --host remarkable-usb
scripts/remarkable build all --clean
scripts/remarkable package --version 2.1.0 --skip-build
```

GitHub CI runs only `scripts/remarkable check host`. It has no tablet, NAS,
tailnet, or deployment credentials. Physical-device deployment remains a
manual operation after the complete local release gate passes.

Key guides:

- [Security](docs/security.md)
- [Recovery](docs/recovery.md)
- [Backups](docs/backups.md)
- [Custom software](docs/custom-software.md)
- [Paperboard](docs/paperboard.md)
- [PaperTerm](docs/paperterm.md)
- [Relay](docs/relay.md)
- [Agent tools](docs/agent-tools.md)
- [Remote](docs/remote.md)
- [Providers](docs/providers.md)
- [Resources](docs/resources.md)

## License

[MIT](LICENSE)
