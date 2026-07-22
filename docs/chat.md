# Chat

Chat is a native, landscape-first Paper Pure client for private OpenClaw
conversations. It is a separate AppLoad application; it does not replace the
stock notebook UI, Paperboard, Canvas, or PaperTerm.

## Behavior

- Opening Chat shows a full-screen conversation list. Selecting a row opens a
  full-screen conversation.
- New chats use a `paperchat:` session key and a selected OpenClaw agent.
- Existing OpenClaw sessions can be viewed and continued. Continuations use
  `deliver: false`, so a reply requested from Chat stays in Chat instead of
  also appearing in Telegram.
- Replies remain queued while Chat is closed. Posting never launches the app.
- The private relay cache is bounded to 100 conversations and 500 messages per
  conversation. Titles, bodies, and queued action payloads are AES-256-GCM
  encrypted with the relay master key.
- The outbox uses stable UUIDs. Reconnect retries cannot enqueue the same action
  twice.
- Search and pin are local. Rename and archive are applied to OpenClaw. Hide is
  a reversible local alternative to destructive deletion.

The first release supports typed messages and rendered Markdown text. Image
attachments and tablet-originated image uploads are deliberately deferred; the
client does not silently import an attachment while claiming it was displayed.

## Components

```text
Chat AppLoad app -> private Paperboard relay -> paperchat OpenClaw plugin
```

The existing relay container owns the encrypted cache and outbox. No additional
NAS container, VM, public port, or Tailscale Funnel is required. The plugin is a
small bundled JavaScript artifact loaded into the existing OpenClaw gateway.

## Build and deploy

```bash
scripts/remarkable build chat
scripts/deploy-chat.sh --dry-run
scripts/remarkable deploy chat
```

Deployment validates `imx93-tatsu`, `aarch64`, and the approved OS manifest,
creates and verifies a backup, installs transactionally, restarts AppLoad only
over `remarkable-usb`, and verifies the runtime invariant afterward.

Build the OpenClaw bridge with:

```bash
scripts/build-openclaw-paperchat.sh
sha256sum --check integrations/openclaw-paperchat/dist/index.js.sha256
```

Provision its dedicated bridge credential through an SSH tunnel to the relay's
loopback-only admin listener:

```bash
scripts/provision-paperchat-client.sh --device DEVICE_ID
```

The script writes an ignored, mode-0600 environment file and never prints the
token. The client receives only `chat:bridge:read` and `chat:bridge:write`.
It reuses the currently deployed OpenClaw Paperboard relay URL when available;
set `PAPERCHAT_RELAY_URL` explicitly only when provisioning a different relay.

The OpenClaw VM needs a mode-0600 environment file containing exactly the
owner-specific values below. Keep it under ignored `secrets/`; never commit or
print it.

```dotenv
PAPERCHAT_RELAY_URL=https://relay.example.invalid
PAPERCHAT_RELAY_TOKEN=replace-with-scoped-client-token
PAPERCHAT_DEVICE_ID=example-device
```

The relay client token needs only `chat:bridge:read` and `chat:bridge:write`.
Set `openclaw_paperchat_enabled: true` in private Ansible inventory after the
artifact and environment file exist. The role verifies the pinned checksum,
installs the extension and protected environment, allowlists `paperchat`, and
restarts the existing gateway.

## Disable, uninstall, and recovery

Disable the bridge first by setting `openclaw_paperchat_enabled: false` in
private inventory and reprovisioning the VM. Messages remain safely queued in
the relay.

Remove or roll back only the tablet frontend with the reviewed USB-only tools:

```bash
scripts/remove-chat.sh --dry-run
scripts/remove-chat.sh
scripts/rollback-chat.sh --dry-run
scripts/rollback-chat.sh
```

Removing Chat does not remove conversations from OpenClaw. `--purge-data` also
removes the tablet's durable unsent outbox and rollback bundle, so it is never
the default.

Chat uses the normal tablet sleep policy and never automates unlock.
