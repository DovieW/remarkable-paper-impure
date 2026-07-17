# Security model

Developer Mode deliberately trades verified platform integrity for owner
control. This project reduces avoidable risk; it cannot make a modified tablet
equivalent to Enterprise Mode.

## Boundaries

- Unlock and recovery remain physical human actions.
- SSH starts over USB, pins the host key, and moves to Wi-Fi only when asked.
- Key authentication is required; private keys and generated root passwords
  never enter chat or Git.
- Tablet identity, architecture, and exact OS are checked before every custom
  bundle deployment.
- User data is backed up and checksummed before software changes.
- Dashboard delivery never foregrounds an app.
- Screen foregrounding is explicit and auditable.
- Device control is a fixed semantic allowlist, never arbitrary shell.
- Remote input accepts bounded taps/swipes only and has an immediate kill
  switch. It never accepts passcodes or text.

## Relay

The public relay listener is private-tailnet HTTPS. The admin listener remains
on host loopback. Tailscale Funnel is forbidden. Tokens are high entropy,
hashed at rest where appropriate, scoped to `dashboard:*`, `screen:*`,
`status:read`, and narrow `device:*` capabilities, and revocable through the
admin control plane. Upstream provider credentials are authenticated-encrypted
with the master key.

Source ignored environment files in a subshell. Never print, commit, or send
device, client, admin, provider, Tailscale, or private hostname values.

## Content safety

- Dashboard text rejects HTML and Markdown images.
- Uploaded images are normalized before storage.
- Reader fetches require public HTTPS and revalidate DNS/redirects to prevent
  server-side request forgery. They are capped at 2 MiB, use no browser cookie
  jar, and execute no page JavaScript. Search terms go to DuckDuckGo Lite.
- Reader bookmarks retain only the public URL, page title, and creation time;
  they are device-scoped and capped at 100. In-session navigation history is
  not written to the relay database.
- Screenshots are returned ephemerally and are not retained by the relay.
- Screen history is capped at 100 displays; event and asset retention is
  bounded.

## Operational rules

1. Review upstream source and pin artifacts/checksums before root installation.
2. Never use `curl | sh` as root.
3. Do not modify boot/recovery partitions without explicit authorization and a
   tested recovery route.
4. Keep a passcode enabled during normal use. Temporarily disabling Auto sleep
   is acceptable during supervised work; restore it afterward.
5. Do not use this device for enterprise/confidential data without written
   organizational approval.
6. Run `scripts/release-check.sh` before a public push.

If a credential may have appeared in output or history, revoke/rotate it first;
removing the text from the current working tree is not sufficient.
