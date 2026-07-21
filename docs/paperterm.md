# PaperTerm

PaperTerm is a small native terminal application for the Paper Pure. It runs
beside Paperboard under AppLoad and is intended primarily for opening SSH
sessions from the tablet to explicitly configured hosts.

It is deliberately not a browser terminal, a relay endpoint, or an agent tool.
The backend is a compiled C program using a PTY and a pinned copy of libvterm;
the foreground is QML optimized for the e-ink display. It does not require
Node.js, Python, a web browser, or a resident server on the tablet.

The terminal renderer bundles the fixed-width `NotoMono Nerd Font Mono` from
Nerd Fonts `v3.4.0`. Its archive and extracted font are checksum-pinned during
the build, and the SIL Open Font License is shipped with the application.
Box drawing, block elements, arrows, Powerline separators, Nerd Font private
use symbols, common geometric symbols, combining sequences, double-width cells,
and other common TUI glyphs render in fixed terminal columns. Unsupported
glyphs use the system fallback font while their terminal column remains fixed.
PaperTerm currently favors a responsive plain-text frame over per-cell color
and weight styling; rich-text rendering proved too slow and unreliable on the
tablet.

The on-screen keyboard includes Escape, modifiers, Tab, Backspace, Enter,
Home, End, Delete, Page Up, Page Down, and all four arrow keys. A physical
keyboard can send the same navigation keys.

A left-aligned macro rail provides six one-tap key chords. Without a `macros`
entry, PaperTerm defaults to `TMUX` (`Ctrl+Space`), `C-C`, `C-D`, `C-Z`, `C-L`,
and `C-R`. Set `"macros": []` to hide the rail, or define up to six entries:

```json
"macros": [
  { "label": "TMUX", "key": "space", "ctrl": true },
  { "label": "C-C", "key": "c", "ctrl": true }
]
```

Labels are printable ASCII up to 16 characters. A key is a lowercase printable
ASCII character or one of `space`, `enter`, `tab`, `backspace`, `escape`,
`up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, and
`delete`. The optional `ctrl`, `alt`, and `shift` fields must be booleans.
Macros emit only the declared structured key chord; they do not contain or
evaluate shell commands. `Ctrl+Space` is emitted as the NUL byte expected by
tmux.

## Security boundary

- Profiles are read from `/home/root/.config/paperterm/profiles.json`. The file
  must be owned by root, be a regular file, and have mode `0600`.
- The profile list is loaded once when PaperTerm starts and remains available
  when a session disconnects. Reopen PaperTerm after intentionally changing
  the profile configuration.
- AppLoad control messages always carry a nonempty payload. AppLoad transports
  headers and bodies as separate `SOCK_SEQPACKET` records; a zero-length body
  can otherwise be mistaken for a closed backend socket.
- Profiles describe structured arguments. PaperTerm never evaluates profile
  values through a shell.
- Passwords are not supported or stored. Use Tailscale SSH or a dedicated
  least-privilege SSH key.
- Traditional SSH requires strict host-key checking. Enroll and verify the
  target host key before connecting.
- Scrollback exists only in the process memory and disappears when PaperTerm
  exits.
- PaperTerm is a sensitive foreground. It cannot be remotely launched and
  remote input injection remains disabled while it is open. Explicit,
  authenticated screenshots are available for diagnostics, but may contain
  terminal output, paths, commands, or secrets. Screenshots are ephemeral and
  must not be committed or retained unnecessarily. Remote exit remains
  available as a recovery action.
- The terminal backend runs as root because AppLoad applications do. A local
  shell is therefore disabled unless `allow_local_shell` is explicitly set.

Tailscale SSH is the preferred transport on a userspace-networking tablet. The
tablet's Tailscale client supplies the SSH proxy. The configuration helper
merges Tailscale's verified peer host-key set into Dropbear's strict
`known_hosts` file before a profile is used.
Tailnet ACLs should allow the tablet to reach only the intended accounts and
hosts. Do not enable Funnel or expose SSH publicly.

## Profile modes

- `tailscale-ssh`: runs Dropbear through a fixed compiled `tailscale nc` proxy.
  This is the default recommendation for tailnet hosts and works with the
  tablet's userspace-networking Tailscale service without requiring OpenSSH.
- `tailscale-key`: uses the same private Tailscale proxy but authenticates to a
  standard OpenSSH server with PaperTerm's dedicated Ed25519 key. Use this when
  the destination does not run the Tailscale SSH server or has no matching
  tailnet SSH policy.
- `ssh`: runs Dropbear `dbclient` with strict host-key checking and a dedicated
  identity file.
- `local`: starts `/usr/bin/bash` only when `allow_local_shell` is true. This is
  an expert feature, not the default.

A `tailscale-ssh` profile may set `"session": "windows-powershell"`. This uses
the same authenticated WSL destination but starts the fixed Windows PowerShell
executable through WSL interoperability. PaperTerm deliberately does not
accept arbitrary startup command strings.

Copy [the example profile](../config/paperterm-profiles.example.json) to an
ignored local file, replace the reserved examples locally, and install it with
the configuration script. Never commit real usernames, hostnames, addresses,
host keys, or account details.

## Lifecycle

Build:

```bash
scripts/build-paperterm.sh --clean
```

For a checksummed runtime archive that another agent can install without
shipping SDK object files, build both applications and package them:

```bash
scripts/remarkable build all --clean
scripts/remarkable package --version VERSION --skip-build
```

The first build downloads the pinned libvterm source, verifies its exact Git
commit, and cross-compiles it with the official Paper Pure SDK. Subsequent
builds reuse the inspected checkout under the ignored `build/` directory.

Validate a local profile without changing the tablet:

```bash
scripts/configure-paperterm.sh --config config/paperterm-profiles.local.json --dry-run
```

For standard OpenSSH over the private tailnet, create the tablet-only key and
pin the destination's trusted Ed25519 host key in one configuration pass:

```bash
scripts/configure-paperterm.sh \
  --config config/paperterm-profiles.local.json \
  --generate-key \
  --public-key-output "$HOME/.ssh/paperterm-tablet.pub" \
  --known-host-name example-wsl-host \
  --known-host-public-key /etc/ssh/ssh_host_ed25519_key.pub
scripts/authorize-paperterm-key.sh --public-key "$HOME/.ssh/paperterm-tablet.pub"
```

The private key never leaves the tablet. The exported public key and the
destination host key are not secrets, but they remain owner-specific and must
not be committed.

Install or update:

```bash
scripts/backup.sh --host remarkable-usb
scripts/deploy-paperterm.sh --host remarkable-usb
scripts/configure-paperterm.sh --host remarkable-usb --config config/paperterm-profiles.local.json
scripts/device-smoke-test.sh --host remarkable-usb
```

Disable by exiting the application. Remove the bundle while retaining private
configuration:

```bash
scripts/remove-paperterm.sh --host remarkable-usb
```

Use `--purge-data` only when the profiles and any dedicated PaperTerm key should
also be permanently removed. The deploy script keeps the previous bundle for
rollback. If an update fails, use `scripts/rollback-paperterm.sh`.

## WSL target on a Windows Tailscale host

When Tailscale already runs on Windows, do not enroll WSL 2 as a second
Tailscale node. Tailscale documents nested packet-size problems when both are
active. Instead, target the Windows node's MagicDNS name with `tailscale-key`.
Windows' WSL relay can expose WSL's standard OpenSSH listener to the private
tailnet while the dedicated PaperTerm key still authenticates inside WSL.

Use a second profile with `"session": "windows-powershell"` to authenticate
through the same WSL SSH relay and immediately start the fixed Windows
PowerShell executable. This provides distinct WSL and Windows sessions without
installing a second Windows SSH server or exposing port 22 publicly.

If Windows exposes WSL's SSH listener only through a loopback `wslrelay`, run
the reviewed Windows helper from an elevated PowerShell session:

```powershell
.\scripts\configure-windows-wsl-ssh-relay.ps1
```

It binds a Windows port proxy only to the Tailscale IPv4 address and restricts
the matching firewall rule to Tailscale's CGNAT source range. Remove it with
`-Remove`; inspect the proposed changes with `-WhatIf`.
