# Agent operating contract

This repository exists so an AI coding agent can safely help a human bring a
new reMarkable Paper Pure from Developer Mode to a backed-up, recoverable,
key-accessible development device, then build whatever the owner chooses.

Read this file completely before interacting with a tablet.

## Non-negotiable safety rules

1. Never ask the user to paste the generated root password, a private key, an
   account token, or confidential document contents into chat. Password entry
   happens directly in the user's local terminal.
2. Begin over the physical USB connection at `10.11.99.1`. Do not scan the
   user's LAN or guess a Wi-Fi address when USB is available.
3. Learn and pin the SSH host key over that physical connection before trusting
   Wi-Fi. Never publish the resulting fingerprint: it identifies one tablet.
4. Identify the device, architecture, and installed OS before any write. Stop
   if it is not a Paper Pure or if a proposed package does not explicitly
   support the observed version.
5. Back up and verify user data before installing, upgrading, removing, or
   repairing custom software.
6. Never run unreviewed remote shell pipelines as root. Download artifacts on
   the host, inspect the installer, verify a pinned checksum/signature, then
   transfer them.
7. Do not modify boot partitions, the partition table, recovery components, or
   protected OS files unless the user explicitly requests that work and a
   tested recovery route exists.
8. Keep personal data out of this repository and its Git history. Examples in
   docs must use placeholders or reserved example addresses.
9. Treat Developer Mode as unsuitable for enterprise-managed or confidential
   work data unless the responsible organization has explicitly approved it.
10. Explain every physical or destructive step before the user performs it.

## Trust order

Use sources in this order:

1. Current official reMarkable developer and recovery documentation.
2. Current upstream project source, releases, constraints, and issue tracker.
3. `remarkable.guide` for community procedures.
4. Awesome lists only for discovery.

If sources disagree, prefer the higher-trust source and tell the user. Browse
again when versions, URLs, support claims, or release artifacts may have
changed.

## Private local context

Owner-specific context belongs in the ignored root file `PERSONAL.md`. If it
does not exist, create it from `PERSONAL.example.md`. Appropriate entries
include local paths, tablet fingerprints, LAN addresses, MAC addresses, backup
locations, and recovery-host notes.

Treat `PERSONAL.md` as sensitive even though it must not contain passwords,
private keys, recovery codes, or broadly privileged tokens. Never force-add
it, quote its values in public documentation, or expose its contents in chat
unless the user explicitly requests a particular non-secret value.

## Autonomy before interruption

Follow [docs/agent-autonomy.md](docs/agent-autonomy.md). Complete routine
navigation, launching, screenshot capture, log inspection, and verification
yourself when reviewed local tooling can do so safely. If a capability is
missing, prefer building a narrow, reusable SSH-only tool and documenting it
over repeatedly delegating mechanical steps to the owner.

Do not cross authentication or recovery boundaries. Never request, store, or
inject the tablet passcode. A human unlock after reboot or lock, cable changes,
and physical recovery-button sequences are legitimate exceptions. Group such
requests and keep them minimal.

## Zero-to-running workflow

### 1. Human preparation

Walk the user through [docs/agent-quickstart.md](docs/agent-quickstart.md).
Developer Mode and unlocking are physical steps. Enabling Developer Mode may
factory-reset the tablet, so confirm cloud sync or another backup first.

For longer supervised work, ask the owner to connect power, unlock once, and
temporarily disable Auto sleep while keeping the passcode enabled. Restore the
normal sleep policy at the end of the session.

### 2. Establish SSH

From WSL/Linux, first inspect the bootstrap:

```bash
bash -n scripts/bootstrap-ssh.sh
scripts/bootstrap-ssh.sh --dry-run
```

Then ask the user to run this in their own terminal:

```bash
scripts/bootstrap-ssh.sh
```

The script creates a dedicated Ed25519 key and SSH config fragment, displays
the USB host-key fingerprint for local confirmation, and invokes
`ssh-copy-id`. The user enters the generated tablet password locally. Do not
request, echo, log, or transcribe it.

Enable Wi-Fi SSH only when requested and only on a trusted LAN:

```bash
scripts/bootstrap-ssh.sh --enable-wifi
```

### 3. Inventory before writes

```bash
ssh remarkable-usb 'hostname; uname -m; cat /etc/os-release'
scripts/status.sh --host remarkable-usb
```

Expected initial Paper Pure signals include `aarch64` and platform hostname
`imx93-tatsu`. The OS image can differ from this repository's tested baseline.
Record compatibility facts, but do not commit IP/MAC addresses, fingerprints,
serials, tokens, passwords, or document metadata.

### 4. Back up and verify

```bash
scripts/backup.sh --host remarkable-usb --dry-run
scripts/backup.sh --host remarkable-usb
```

Backups default to `~/remarkable-backups`, outside the repository. Verify the
generated `SHA256SUMS`. Do not use `--include-sensitive-config` unless the user
understands that `xochitl.conf` may contain the root password in plaintext and
the destination is encrypted and access-controlled.

### 5. Prepare recovery

Read [docs/recovery.md](docs/recovery.md) and verify current official recovery
instructions for the host OS. In WSL, recovery-mode USB belongs to Windows
unless intentionally passed through; do not discover this for the first time
during an emergency. Never run recovery merely as a test.

### 6. Add capabilities incrementally

Discuss the owner's goal, research current Paper Pure support, and make one
reversible change at a time. A launcher, reader, dashboard, Tailscale service,
or custom Qt application can coexist with the stock UI, but display hooks and
OS integrations are firmware-sensitive.

The stack in [docs/custom-software.md](docs/custom-software.md) is an observed
example for OS `3.27.3.0`, not a universal installer. Revalidate all package
constraints and artifact hashes before reproducing it on another tablet.

## Change quality bar

Scripts must use strict shell mode, quote variables, validate prerequisites,
fail closed on uncertain target identity, support a non-mutating dry run where
useful, and document their effects. Device-changing additions need install,
verification, update, disable, uninstall, and recovery notes.

Before committing, run at least:

```bash
bash -n scripts/*.sh
scripts/bootstrap-ssh.sh --dry-run
git diff --check
```

Also scan tracked files and history for secrets and personal device/network
identifiers before any public push.
