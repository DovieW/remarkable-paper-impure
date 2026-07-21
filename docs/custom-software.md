# Custom software stack

This document records the first Paper Pure application stack installed on
July 14, 2026. It was verified against reMarkable OS image `3.27.3.0` on the
`aarch64`/`rmppure` platform.

## Installed stack

| Component | Installed version | Purpose |
| --- | --- | --- |
| Vellum | `0.3.1-r0` | Signed package management |
| Xovi | `0.3.3-r2` | Extension framework loaded into the stock UI |
| Xovi extensions | `19.0.0-r1` | Shared extension support |
| Qt resource rebuilder | `19.0.0-r1` | OS-specific stock-UI resource mapping |
| AppLoad | `0.5.3-r1` | Application launcher inside the stock UI |
| KOReader | `2026.03-r4` | E-book and document reader |
| PaperTerm | repository build | Native PTY terminal for reviewed SSH profiles |

Vellum recognizes the virtual device packages `rmppure`, `aarch64`, and
`remarkable-os=3.27.3.0`. AppLoad's package constraint allows reMarkable OS
`>=3.26` and `<3.28`; it should not be carried onto another OS release without
running Vellum's compatibility check.

## Installation record

Vellum was installed from locally downloaded release artifacts rather than an
unreviewed remote shell pipeline. The following artifacts were verified before
being transferred over pinned USB SSH:

| Artifact | SHA-256 |
| --- | --- |
| Vellum `v0.3.1` bootstrap | `18a4b0123160a1b547fa9f396005ce8c9caf2330bf3ff6fa39bb2eb27891cca8` |
| Vellum aarch64 binary | `bf0e603d7c70a93e32b454fbe0c089851200702bc8cb4ec43559f27909d302fd` |
| Vellum apk-tools `v3.0.3` aarch64 | `dab5b2b615cae41fd90a99fc6bdca87d26d04c0755440bded6b4832547c09cf7` |
| Vellum package signing key | `2cf3d32486a5b231170586475221fc222887ccb8a3b9345b577a88d2908bc847` |

The bootstrap created `/home/root/.vellum`, generated a local package-signing
key, and configured the signed `https://packages.vellum.delivery` repository.
The temporary bootstrap directory was removed after installation.

Before activation, Xovi's resource builder generated a 646,221-byte hashtable
for OS `3.27.3.0` containing 19,609 cached entries. AppLoad then loaded inside
the stock `xochitl` process through `LD_PRELOAD=/home/root/xovi/xovi.so`.

## Using AppLoad and KOReader

Open AppLoad from its entry in the stock interface, then select KOReader.

AppLoad supports one fullscreen foreground application at a time. To close a
fullscreen application, swipe from the center-top of the display toward the
center. Long-pressing an application icon requests windowed mode, but use
KOReader fullscreen unless its current Paper Pure behavior has been verified
in a window.

KOReader is stored under:

```text
/home/root/xovi/exthome/appload/koreader
```

Its AppLoad manifest uses the aarch64 QTFB shim with native input and an RGB565
framebuffer. KOReader's own OTA updater is disabled by the Vellum package;
update it through Vellum so package state remains coherent.

Two interactive launches were verified on the Paper Pure. Display updates,
touch input, application startup, and return to the stock interface worked.
Both runs ended with exit code `0` and `QProcess::NormalExit`, and no KOReader
process remained afterward.

## PaperTerm

PaperTerm is installed as a separate AppLoad application. It uses the tablet's
existing Dropbear client and prefers the installed Tailscale SSH wrapper for
tailnet targets. It is not remotely launchable and remote input is blocked
while it is foregrounded. Explicit authenticated screenshots are supported
for diagnostics and should be treated as sensitive terminal output.
Configuration and lifecycle instructions live in [paperterm.md](paperterm.md).

## Health check

From WSL, run:

```bash
scripts/status.sh
```

The expected `xochitl-mode` is `xovi-appload`. The root filesystem should be
mounted read-only, and `xochitl` should be active.

## Temporarily return to the stock UI

Disable Xovi/AppLoad without uninstalling packages:

```bash
ssh remarkable /home/root/xovi/stock
```

Wait at least 15 seconds and confirm the stock UI is responsive before another
mode change.

Re-enable it:

```bash
ssh remarkable /home/root/xovi/start
```

These scripts restart `xochitl`. Save or close active documents first. Do not
run `stock` and `start` back-to-back: rapid restarts can trip systemd's
`start-limit-hit` protection and cause the tablet to reboot into safe stock
mode. If that happens, let the reboot finish, then run:

```bash
ssh remarkable-usb \
  'systemctl reset-failed xochitl.service; /home/root/xovi/start'
```

Allow at least 15 seconds for the UI and network services to settle afterward.
This recovery was tested successfully, and AppLoad returned with the root
filesystem read-only.

## Updates

Before a reMarkable OS update:

```bash
ssh remarkable '/home/root/.vellum/bin/vellum check-os <new-version>'
```

If any package is incompatible, remain on the current OS or return to stock
mode and wait for compatible packages. After an OS update, follow current
Vellum guidance; package re-enablement and a new Qt resource hashtable may be
required.

Update the package index and installed packages with:

```bash
ssh remarkable '/home/root/.vellum/bin/vellum update && /home/root/.vellum/bin/vellum upgrade'
```

Do not update KOReader through its internal updater.

## Removal and rollback

Remove KOReader while keeping AppLoad:

```bash
ssh remarkable '/home/root/.vellum/bin/vellum del koreader'
```

Refresh AppLoad afterward by restarting Xovi:

```bash
ssh remarkable /home/root/xovi/start
```

Before removing AppLoad or Vellum, return to the stock UI:

```bash
ssh remarkable /home/root/xovi/stock
```

Then use Vellum's package removal or complete self-uninstall command. Review
the proposed dependency removals before confirming them. A complete Vellum
uninstall, including managed packages, is:

```bash
ssh remarkable '/home/root/.vellum/bin/vellum self uninstall --all'
```

Do not use the tablet's built-in factory reset as an application uninstaller.
Use the prepared [recovery procedure](recovery.md) only if normal rollback is
not possible.

## Upstream references

- [Vellum CLI](https://github.com/vellum-dev/vellum-cli)
- [Vellum package registry](https://github.com/vellum-dev/vellum)
- [Xovi](https://github.com/asivery/xovi)
- [AppLoad](https://github.com/asivery/rm-appload)
- [KOReader](https://github.com/koreader/koreader)
