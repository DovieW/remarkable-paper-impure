# Zero-to-running quickstart

This guide covers the safe common foundation: Developer Mode, USB SSH, device
identification, backup, and recovery readiness. It deliberately does not
auto-install a launcher or reader because those integrations depend on the
tablet's current OS.

## What the owner must do on the tablet

1. Sync or export anything important.
2. Read reMarkable's current [Developer Mode documentation](https://developer.remarkable.com/documentation/developer-mode).
3. Enable Developer Mode. Expect the documented factory reset and security
   tradeoff.
4. Complete setup, unlock the tablet, and connect it with a data-capable USB
   cable.
5. Enable **Settings → General settings → Storage → USB web interface**.
6. Open the on-device copyright/licenses information and locate the generated
   SSH password. Keep that screen private.

The page at `http://10.11.99.1` is a useful USB connectivity check. SSH uses
the same tablet address.

## What to do on WSL or Linux

Clone and enter the repository, then inspect the bootstrap:

```bash
git clone https://github.com/DovieW/remarkable.git
cd remarkable
bash -n scripts/bootstrap-ssh.sh
scripts/bootstrap-ssh.sh --dry-run
```

Run the real bootstrap in your local terminal:

```bash
scripts/bootstrap-ssh.sh
```

Confirm the displayed host-key fingerprint only while the expected tablet is
physically connected. When prompted, type the generated device password into
the terminal. Do not paste it into an AI chat, a script, or a config file.

Verify key-only access and identify the tablet:

```bash
ssh remarkable-usb
scripts/status.sh --host remarkable-usb
```

If `10.11.99.1` opens in Windows but not WSL, check that the reMarkable USB
network adapter is visible to Windows and that WSL networking/firewall policy
permits the connection. Do not respond by scanning unrelated LANs.

## Back up before customizing

```bash
scripts/backup.sh --host remarkable-usb --dry-run
scripts/backup.sh --host remarkable-usb
```

The final line gives the backup path. Run the printed checksum verification
command. Backups belong outside this Git repository.

## Optional Wi-Fi SSH

On a trusted private LAN only:

```bash
scripts/bootstrap-ssh.sh --enable-wifi
ssh remarkable
```

Disable it when not needed:

```bash
ssh remarkable rm-ssh-over-wlan off
```

Never port-forward tablet SSH to the internet.

## Decide what to build

At this point the tablet is ready for an agent to research and implement a
specific goal. Good first projects are a read-only status/dashboard viewer,
a small Qt application, or a currently supported reader/launcher stack.

Before choosing software, compare the exact output of `scripts/status.sh`
with upstream device and OS constraints. The repository's recorded KOReader
stack worked on OS `3.27.3.0`; that does not establish compatibility with a
newer release.
