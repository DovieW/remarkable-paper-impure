# Backups

Back up the Paper Pure before installing or updating third-party software.
The repository provides a read-only WSL backup helper:

```bash
scripts/backup.sh
```

By default, backups are written outside the Git repository under
`~/remarkable-backups/`. Each timestamped backup contains:

- a compressed archive of the stock document data managed by `xochitl`;
- device, OS, filesystem, mount, and selected service metadata;
- the installed public SSH authorization entries;
- a SHA-256 manifest covering every captured file; and
- a note recording whether sensitive configuration was included.

The script uses key-authenticated SSH in batch mode, performs no device writes,
and verifies the resulting archive and checksum manifest before publishing the
backup directory.

## Dry run

Verify connectivity and show the planned destination without copying data:

```bash
scripts/backup.sh --dry-run
```

## Sensitive configuration

`/home/root/.config/remarkable/xochitl.conf` may contain the generated root
password in plaintext. It is excluded by default. It can be included only by
an explicit option:

```bash
scripts/backup.sh --include-sensitive-config
```

Use that option only when the destination is encrypted and access controlled.
The generated device password must never be committed to Git.

## Limitations

This is a live, file-level backup, not a block-level disk image. The stock UI
remains active during the copy. It protects user documents and records useful
state, but it is not a substitute for the official Paper Pure recovery tool.

The archive stores reMarkable's internal document data so files, metadata, and
annotations remain together. It is not intended to be opened as a collection
of ordinary PDFs.

## Verification

Every backup includes `SHA256SUMS`. Verify it with:

```bash
cd ~/remarkable-backups/<backup-directory>
sha256sum -c SHA256SUMS
```

## Source reference

- [reMarkable Guide: Backing Up Your Data](https://remarkable.guide/guide/access/backup.html)

