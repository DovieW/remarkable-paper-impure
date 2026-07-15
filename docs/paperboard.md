# Paperboard

Paperboard is a private, agent-friendly output queue for the Paper Pure. An
agent can post a message, update a progress card, push a normalized image, or
clear the queue. Nothing steals focus: delivery waits at the relay until the
owner opens Paperboard from AppLoad.

```text
CLI or MCP tool ──HTTPS/Tailscale──> relay ──long poll──> Paper Pure
                                     │                    Paperboard QML
TRMNL hosted or Terminus ────────────┘                    (foreground only)
```

The tested path is WSL relay → Windows Tailscale Serve → tablet Tailscale
userspace SOCKS proxy → Paperboard. The private DNS name and all credentials
remain in ignored mode-0600 files.

## What version 1 supports

- Message, progress, and image cards.
- Urgent, pinned, normal, and ambient ordering.
- Replace keys for one continuously updated status card.
- Default five-minute TTL, maximum 24 hours, or explicit pinning.
- Hidden-by-default chrome, horizontal card swipes, edge-swipe controls, and
  visible two-second feedback for every action.
- Previous/next, pin, dismiss, persistent ambient mode, refresh, and return.
- Authenticated long polling with cursor acknowledgements and offline catch-up.
- TRMNL Hosted BYOD and self-hosted Terminus as optional ambient providers.
- Client-scoped API, CLI, and MCP parity for cards, delivery status,
  foreground navigation, and the separate interactive Canvas application.
- No background display takeover. The app and relay polling client exist only
  while Paperboard is in the foreground.

The RETURN control calls AppLoad's `terminate()` operation, which kills the
backend and immediately unloads every Paperboard frontend. It deliberately
does not also emit the frontend `close` signal: mixing the two lifecycle paths
can race the permanent unload and allow a resident frontend to relaunch the
backend later.

The top and bottom chrome do not consume content space. They begin hidden;
swipe upward from the bottom or downward from the top to reveal them. A
horizontal swipe moves between cards and leaves ambient mode. Ambient mode
continues selecting the highest-ranked ambient frame as provider snapshots
change until the owner exits it.

## Landscape orientation

Paperboard deliberately uses the Paper Pure's native `1872x1404` landscape
space. If AppLoad presents a portrait `1404x1872` application surface, the QML
frontend rotates its complete landscape canvas by 90 degrees. If AppLoad
already presents a landscape surface, no additional rotation is applied. This
keeps Paperboard horizontal without changing the stock notebook application's
orientation behavior.

The relay normalizes uploaded and provider images to `1872x1404` with
aspect-fit scaling. Landscape sources use the full canvas; portrait sources
remain uncropped and receive side margins. Agent message and progress cards
reflow natively in the wider layout.

## Build and deploy the tablet application

Install the pinned official Paper Pure SDK outside the repository, then build:

```bash
scripts/setup-paperboard-sdk.sh --dry-run
scripts/setup-paperboard-sdk.sh
scripts/build-paperboard.sh --clean
scripts/deploy-paperboard.sh --dry-run
scripts/deploy-paperboard.sh
```

The deployment is constrained to `imx93-tatsu`, `aarch64`, and reMarkable OS
`3.27.x`. It installs only below the persistent home partition and retains the
previous AppLoad bundle for rollback.

## Connect it to a provisioned relay

Provisioning writes two ignored files:

```text
secrets/tablets/<device>.conf       # copy to the tablet
secrets/clients/<client>.env        # source on an authorized agent host
```

Install the tablet's redacted relay config without printing its token:

```bash
scripts/configure-paperboard.sh \
  --relay-config secrets/tablets/paper-pure.conf --dry-run
scripts/configure-paperboard.sh \
  --relay-config secrets/tablets/paper-pure.conf
```

Install and start the pinned ARM64 Tailscale binaries in userspace mode:

```bash
scripts/install-paperboard-tailscale.sh --dry-run
scripts/install-paperboard-tailscale.sh
scripts/start-paperboard-tailscale.sh --hostname paper-pure
```

The one-time Tailscale authentication URL is a legitimate human boundary. The
service changes no kernel routes, creates no system service, and listens only
on `127.0.0.1:1055` for SOCKS5. See [Tailscale](tailscale.md).

## Send output

```bash
set -a
. secrets/clients/local-agent.env
set +a

pnpm paperboard show --device paper-pure \
  --title "Build complete" --body "All checks passed." --priority urgent

pnpm paperboard show --device paper-pure \
  --title "Rendering" --progress 10 --replace-key current-build

pnpm paperboard show --device paper-pure \
  --title "Dashboard" --image ./dashboard.png --ttl 900

pnpm paperboard status --device paper-pure
pnpm paperboard clear --device paper-pure
```

The `show` response contains the card ID used by `update`. For agent-native
integration, use [Agent tools](agent-tools.md).

## E-ink behavior

Snapshots are applied at most once every two seconds. Image decode requests a
full refresh; message/progress changes request a periodic full refresh after
ten changed frames. There are no animations. One-second pushes are accepted by
the relay but deliberately coalesced on screen; for chat or live status,
two-second visual updates are the practical floor and one-minute updates are
gentle on the display.

## Portable and desk modes

- **Portable:** let the tablet sleep normally. Output queues at the relay and
  catches up when Paperboard is opened. No wake daemon is installed.
- **Desk session:** connect power, keep Paperboard open, and temporarily turn
  off Auto sleep. Restore Auto sleep afterward. The relay long poll normally
  delivers changes within a couple of seconds.

Do not disable the passcode. Paperboard cannot unlock or bypass a locked
tablet.

## Launch policy

Paperboard is deliberately manual-launch through AppLoad. Do not configure it
to start on boot or when a card is posted: agent and provider output must queue
without interrupting notebooks, reading, or the stock interface. RETURN uses
AppLoad's permanent unload path, so later relay activity cannot relaunch the
tablet client. Auto sleep is independent of this policy and may remain disabled
during an owner-approved powered desk deployment.

## Legacy single-image mode

`scripts/configure-paperboard.sh --from-file FILE` remains supported for a
single HTTPS PNG URL. Relay mode is recommended for authenticated cards,
providers, agents, and safe queueing.

## Remove or roll back

```bash
scripts/stop-paperboard-tailscale.sh
scripts/configure-paperboard.sh --remove
scripts/remove-paperboard.sh --dry-run
scripts/remove-paperboard.sh
```

Use `--purge-data` only when local config, cached snapshots/assets, Tailscale
state, and the previous deployment should also be removed. See the script's
dry run before destructive cleanup.

## Verified baseline

The complete relay path, message/progress replacement, authenticated image
delivery, foreground-only queueing, app reopen/catch-up, and fixed landscape
rendering were exercised on Paper Pure OS `3.27.3.0`. Both a normalized
Terminus image and a native agent message were visually verified across the
horizontal canvas before returning to the stock UI. Hosted TRMNL requires an
owner BYOD API key and was contract-tested rather than called with a real
account. Terminus `0.65.0` was also exercised end to end from a private TrueNAS
SCALE deployment: ambient image delivery, cursor acknowledgement, and a direct
agent card were all rendered on the tablet. See [Providers](providers.md).
