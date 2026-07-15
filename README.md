# Paper Pure developer starter kit

An agent-first toolkit for safely bringing a **reMarkable Paper Pure** from
Developer Mode to a useful, hackable Linux tablet. It keeps the stock writing
experience while making SSH access, backups, recovery preparation, custom
applications, and compatibility research repeatable.

> [!WARNING]
> Developer Mode weakens the tablet's security posture and factory-resets it
> when enabled. Do not use a modified tablet for confidential work data or
> enterprise accounts without explicit organizational approval.

## Give this repository to an AI agent

Clone it in WSL or Linux, open the folder with your agent, and say:

> Read `AGENTS.md` completely. Help me bring my new reMarkable Paper Pure from
> zero to safe, key-authenticated SSH access. Stop for every physical or
> password step, never ask me to paste the device password into chat, and do
> not install optional software until you have identified and backed up the
> tablet.

The agent's complete operating contract is in [AGENTS.md](AGENTS.md). The
human-facing walkthrough is [Zero-to-running quickstart](docs/agent-quickstart.md).

## What is included

- `scripts/bootstrap-ssh.sh` — establishes a dedicated, host-key-pinned USB
  connection and optionally enables trusted-LAN Wi-Fi SSH.
- `scripts/status.sh` — read-only device, service, storage, and custom-stack
  inventory.
- `scripts/backup.sh` — read-only document and state backup with checksums.
- `docs/security.md` — the security boundary and required practices.
- `docs/recovery.md` — official recovery preparation and destructive-action
  warnings.
- `docs/custom-software.md` — a tested Vellum, Xovi, AppLoad, and KOReader
  example for one exact OS version.
- `docs/resources.md` — official and community starting points.
- `docs/agent-autonomy.md` — rules and tooling for agents to launch, observe,
  and verify work themselves while preserving authentication boundaries.
- `docs/paperboard.md` — the private output queue and Paper Pure application.
- `docs/relay.md` — hardened relay deployment for WSL/Windows or Linux.
- `docs/agent-tools.md` — generic CLI and MCP tools for any AI agent.
- `docs/providers.md` — TRMNL Hosted BYOD and Terminus integration.
- `docs/tailscale.md` — private connectivity and tested topology.
- `scripts/configure-paperboard.sh` and `scripts/remove-paperboard.sh` — private
  URL configuration and reversible removal for Paperboard.
- `PERSONAL.example.md` — template for the ignored local `PERSONAL.md` where
  each owner records device- and network-specific context.

## Tested baseline

The repository was initially validated on:

| Property | Value |
| --- | --- |
| Device | reMarkable Paper Pure |
| Platform | `imx93-tatsu` |
| Architecture | `aarch64` |
| reMarkable OS image | `3.27.3.0` |
| Host environment | WSL2 |

This is a compatibility record, not permission to assume every Paper Pure is
still on that version. Agents must inspect the connected device before writes.

## Safe order of operations

1. Read the official Developer Mode warning and sync important documents.
2. Enable Developer Mode, complete the reset, unlock the tablet, and enable
   its USB web interface.
3. Establish key-authenticated USB SSH with `scripts/bootstrap-ssh.sh`.
4. Run `scripts/status.sh --host remarkable-usb` and record the exact platform.
5. Run and verify `scripts/backup.sh --host remarkable-usb`.
6. Prepare a recovery route appropriate to the host computer.
7. Only then evaluate launchers, readers, dashboards, or other applications.

## Paperboard

The first repository-native application is [Paperboard](docs/paperboard.md), a
private output queue for agents and ambient dashboards. Its AppLoad UI renders
messages, progress, and authenticated images; a hardened relay supports CLI,
MCP, TRMNL Hosted BYOD, and self-hosted Terminus. Delivery never launches the
app or interrupts notebooks—queued output appears when the owner opens it.

For the tested WSL setup where Windows is already on the tailnet, start with:

```bash
pnpm install --frozen-lockfile
scripts/init-paperboard-relay.sh
scripts/start-paperboard-relay-windows.sh
```

Then follow [Paperboard](docs/paperboard.md) for tablet Tailscale, provisioning,
deployment, and a first card. Secrets and private hostnames live only under
ignored `secrets/` and `deploy/*/.env` files.

## Project rules

- Prefer official documentation, reviewed source, pinned releases, and hashes.
- Never commit passwords, private keys, device identifiers, LAN addresses,
  account tokens, user documents, or backup data.
- Put necessary owner-specific operational details in ignored `PERSONAL.md`;
  keep actual credentials in a password manager, not Markdown.
- Build reusable SSH-only tooling when it removes routine physical handoffs;
  never automate passcode entry or create an unauthenticated control service.
- Never assume software for reMarkable 1/2, Paper Pro, or Paper Pro Move works
  on Paper Pure.
- Every device-changing procedure needs verification and rollback instructions.
- Do not use unreviewed `curl | sh` or similar root installers.

See [Security](docs/security.md) before changing a device.

## License

The repository is available under the [MIT License](LICENSE).
