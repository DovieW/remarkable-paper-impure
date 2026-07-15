# SSH access from WSL or Linux

## Verified device

The bootstrap design was verified on July 14, 2026.

| Property | Value |
| --- | --- |
| Device | reMarkable Paper Pure |
| Platform hostname | `imx93-tatsu` |
| Architecture | `aarch64` |
| reMarkable OS image | `3.27.3.0` |
| Base OS | Codex Linux `5.7.126` (`scarthgap`) |
| USB device address | `10.11.99.1/27` |
| Wi-Fi address | Discovered locally when explicitly enabled |

On WSL2, remember that its main interface is virtual and recovery-mode USB is
owned by Windows unless deliberately passed through. Normal USB SSH appears as
an IP connection to `10.11.99.1`; no LAN scan is needed.

## Trust and keys

A dedicated Ed25519 client key should live outside this repository:

```text
~/.ssh/remarkable_paper_pure_ed25519
~/.ssh/remarkable_paper_pure_ed25519.pub
```

The private key is mode `600`; the public key is mode `644`. The bootstrap
offers a passphrase prompt. An owner may deliberately leave it empty for
unattended scripts, but protection then depends on the security of the host
account and filesystem. Prefer a passphrase with `ssh-agent` when automation
does not require unattended access. Never copy the private key into this
repository.

Each owner learns their own host key over the physical USB connection. Never
copy a fingerprint from this repository. Both USB and Wi-Fi aliases use
`HostKeyAlias remarkable-paper-pure`, so Wi-Fi must present the identity that
was pinned locally over USB.

On the device, `/home/root/.ssh` is mode `700` and `authorized_keys` is mode
`600`.

## Connecting

Connect over Wi-Fi:

```bash
ssh remarkable
```

Connect over USB:

```bash
ssh remarkable-usb
```

The aliases are defined in a local SSH config fragment, use only the dedicated
identity, and refuse password or keyboard-interactive authentication from the
client after bootstrap.

The Wi-Fi address is assigned by DHCP and may change. If it changes, update
`HostName` in the local `~/.ssh/config.d/remarkable-paper-pure.conf`. Do not
commit the address or tablet MAC to this repository.

## Enabling and disabling Wi-Fi SSH

reMarkable disables SSH over Wi-Fi by default. It was enabled using the
vendor-provided utility after public-key login had been verified over USB:

```bash
ssh remarkable-usb rm-ssh-over-wlan on
```

Turn off Wi-Fi exposure at any time without affecting USB SSH:

```bash
ssh remarkable rm-ssh-over-wlan off
```

The setting is stored as a marker under the persistent data partition and
controls the `dropbear-wlan.socket` systemd unit.

## Security boundary

The local WSL aliases are key-only. The stock Dropbear server on reMarkable OS
`3.27.3.0` still advertises both `publickey` and `password` authentication over
Wi-Fi. Its generated root password therefore remains a possible server-side
login method even though these aliases refuse to use it.

Do not expose port 22 through the internet or configure router port forwarding.
Use Wi-Fi SSH only on a trusted LAN, turn it off when it is not needed, and
consider a separately reviewed server-side password-disable change after a
recovery path and backup have been established.

## Rebuilding access

For a new tablet or a reset tablet, use the reviewed bootstrap and enter the
generated device password directly in the local terminal:

```bash
scripts/bootstrap-ssh.sh
```

Never place the generated root password in chat, scripts, shell history, or
Git.

## Official reference

- [reMarkable Developer Mode](https://developer.remarkable.com/documentation/developer-mode)
