# Paper Pure recovery

Recovery is the last-resort path for leaving developer mode or repairing a
device that no longer boots normally. It is not the routine uninstall method
for applications. Always try a documented application rollback first.

## Verified preparation

On July 14, 2026, the official Linux x86-64 recovery tool version `1.14.1` was
downloaded and tested from this conventional local path:

```text
~/.local/share/remarkable-recovery/1.14.1/rm_recover
```

Its published and locally verified SHA-256 digest is:

```text
2e835990e57737b2c780be7660608cf1eed22a9d87a0014656a2ef0a20b14662
```

The executable's `--help` command runs successfully. No restore or reset has
been attempted.

Re-verify the file before use:

```bash
printf '%s  %s\n' \
  2e835990e57737b2c780be7660608cf1eed22a9d87a0014656a2ef0a20b14662 \
  "$HOME/.local/share/remarkable-recovery/1.14.1/rm_recover" \
  | sha256sum -c -
```

Check the official download page for a newer version and checksum before an
actual recovery. Do not trust this recorded checksum for a different binary.

## Restore versus reset

The official tool exposes two destructive repair operations:

- `restore` reflashes the device software.
- `reset` reflashes the software **and recreates the user partition**, erasing
  user content.

Both operations disable developer mode. Never run either command merely to
test the tool. Prefer `restore` over `reset` when the documented recovery goal
does not require erasing user data.

## Entering recovery mode

The following sequence comes from the official Paper Pure recovery-mode
documentation:

1. Ensure the tablet is powered on.
2. Connect its USB port to a charging source.
3. Hold the power button for 25–30 seconds.
4. Release it for one or two seconds.
5. Press it once for one or two seconds, then release it.

In recovery mode, a regular-production Paper Pure presents USB VID:PID
`2edd:0150`. An early production batch may present `1fc9:014e`.

Holding the power button for seven to ten seconds exits recovery mode without
running the recovery tool. A short press then powers the device on normally.

## WSL caveat

The recovery executable is a Linux program, but recovery-mode USB devices
attach to Windows rather than automatically to WSL2. A WSL user must arrange
and test intentional USB pass-through in advance or use another supported
recovery route.

For an actual emergency, use one of these supported paths:

1. Prefer reMarkable's recovery flow through its Windows desktop application
   on this computer.
2. Use the verified command-line tool from a native Linux host.
3. Set up and test intentional USB pass-through to WSL before an emergency,
   following current Microsoft `usbipd-win` documentation.

Do not put a healthy tablet into recovery mode solely to test USB pass-through.

## Before any recovery

1. Confirm the exact symptom and last modification.
2. Verify the latest backup and its `SHA256SUMS` manifest.
3. Preserve logs or still-accessible user data.
4. Confirm whether `restore` is sufficient or a destructive `reset` is truly
   required.
5. Disconnect unrelated USB devices to reduce target-selection mistakes.
6. Re-read the current official instructions and checksum.

## Official references

- [Recovery mode](https://developer.remarkable.com/documentation/recovery-mode)
- [Recovery tool for Linux hosts](https://developer.remarkable.com/documentation/recovery-for-linux-host)
- [reMarkable software recovery support](https://support.remarkable.com/s/article/Software-recovery)
