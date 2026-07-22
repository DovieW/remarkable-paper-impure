# Chat

Chat is a native, landscape-first Paper Pure client for private OpenClaw
conversations. It is a separate AppLoad application; it does not replace the
stock notebook UI, Paperboard, Canvas, or PaperTerm.

## Behavior

- Opening Chat shows Inbox, Archived, and Removed views. Archived conversations
  stay synchronized with OpenClaw; Removed is a reversible tablet-local state.
  Selecting a row opens the full-screen conversation.
- New chats use a `paperchat:` session key and a selected OpenClaw agent.
- Existing OpenClaw sessions can be viewed and continued. Continuations use
  `deliver: false`, so a reply requested from Chat stays in Chat instead of
  also appearing in Telegram.
- Imported sessions without an OpenClaw label use a compact form of their first
  user message as the title, with a channel-and-date fallback. The generic
  `Conversation` placeholder is not presented as a useful title.
- Replies remain queued while Chat is closed. Posting never launches the app.
- The private relay cache is bounded to 100 conversations and 500 messages per
  conversation. Titles, bodies, and queued action payloads are AES-256-GCM
  encrypted with the relay master key.
- The outbox uses stable UUIDs. The relay atomically leases each action to one
  bridge worker, and an interrupted lease fails closed instead of replaying a
  prompt. Retry is always an explicit user action.
- Assistant streaming and final updates reuse one deterministic message ID, so
  a final response replaces its streaming row instead of becoming a duplicate.
- Changed imported transcripts are reconciled authoritatively. Exact adjacent
  duplicate assistant records are collapsed, and the relay replaces that
  session's cached import atomically so historical duplicates are removed too.
- Back always returns from a conversation to Chat's own conversation list.
  Exit is the only control that returns to AppLoad.
- Search, pin, and Remove are local. Rename and archive are applied to OpenClaw.
- The top bar contains navigation and app controls; the second row contains
  state-aware conversation actions. Every asynchronous action exposes a
  pressed, pending, and final result state. Stop appears only while work is in
  progress, Retry only for a failed user message, and Regenerate only for a
  successfully completed user message.
- Chat and PaperTerm share the same native on-screen keyboard component. Chat
  uses its docked text layout while PaperTerm adds terminal navigation,
  modifiers, and macros.

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

The bridge keeps a mode-0600 state file at
`~/.openclaw/paperchat-bridge-state.json` by default. It records only the
session keys created or adopted by Chat, allowing inventory refreshes to avoid
re-importing those sessions as duplicate history. Override the location with
`PAPERCHAT_STATE_PATH` only when the service account needs a different private
state directory.

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

## Recovery and cleanup

If the bridge is restarted while an action is processing, the relay marks that
action failed after its lease expires. It is not automatically replayed. The
owner can inspect the failure in Chat and choose Retry or Regenerate.

Removing one damaged test conversation is a maintenance operation, not a
tablet feature. Back up both the relay database and the corresponding OpenClaw
session first. Then delete the OpenClaw session and call the relay's
loopback-only, bearer-authenticated admin endpoint:

```text
DELETE /admin/devices/{device}/chat/sessions/{url-encoded-session-key}
```

The endpoint removes that session's encrypted cache, messages, and pending or
completed action records. It is intentionally unavailable on the public relay
listener. Do not add the admin token to a command line or shell history; source
the ignored token file in a subshell.

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
