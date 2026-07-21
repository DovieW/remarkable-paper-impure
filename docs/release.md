# Release procedure

Paperboard uses a manual release gate because deployment reaches a rooted
physical device and depends on an exact firmware compatibility record.

```bash
scripts/remarkable check release
```

The gate performs shell syntax validation, SSH bootstrap and TrueNAS lifecycle
dry-runs, TypeScript build/type checks, all tests, QML bundle build,
operation-registry and custom-app Compose validation, diff whitespace checks,
and non-printing tracked/history secret and private-tailnet scans.

GitHub CI runs the host-only subset on every push and pull request. It validates
the TypeScript workspace, direct client behavior, CLI/MCP operation parity,
shell syntax, serious ShellCheck findings, JSON/SVG sources, and repository
secret patterns. It never receives device, NAS, tailnet, or deployment access.

To produce deterministic runtime archives after the app builds pass:

```bash
scripts/remarkable package --version VERSION --skip-build
(cd build/releases/VERSION && sha256sum -c SHA256SUMS)
```

The release directory contains Paperboard and PaperTerm archives, a checksum
file, and a machine-readable manifest tying the artifacts to a Git commit and
the `imx93-tatsu`/`aarch64` target. Object files, owner profiles, tokens, and
other local configuration are excluded.

Then, with USB preferred:

```bash
scripts/status.sh --host remarkable-usb
scripts/backup.sh --host remarkable-usb --dry-run
scripts/backup.sh --host remarkable-usb
scripts/deploy-paperboard.sh --host remarkable-usb --dry-run
scripts/deploy-paperboard.sh --host remarkable-usb
scripts/deploy-paperterm.sh --host remarkable-usb --dry-run
scripts/deploy-paperterm.sh --host remarkable-usb
scripts/paperboard-doctor.sh --host remarkable-usb
scripts/device-smoke-test.sh --host remarkable-usb
```

Each deployment creates and internally verifies its own backup before writing,
then emits a non-sensitive report containing the content release ID, model, OS,
installation result, activation policy, and rollback availability. Deployment
restarts the Xovi-managed UI services so AppLoad loads new resources. This does
not reboot the tablet, but it briefly interrupts the stock UI. Paperboard may
be activated explicitly; PaperTerm is never remotely launched. Reserve
`--no-restart-xovi` for a verified backend-only build.

The smoke test is read-only. It verifies exact installed content IDs, app
resources, 100x100 icons, services, PaperTerm's offline backend self-test, and
rollback metadata without launching an app, capturing the screen, or injecting
input. Use `--json` for an agent-readable deployment handoff.

Verify Dashboard queue-only behavior, Screen foreground/presentation and
history, Reader address/search navigation, links, back/forward/reload,
bookmark persistence, and rejection of a private URL, plus tap-to-toggle
chrome, one-hour handoff configuration, Exit, screenshot, and rollback
metadata. Capture no confidential display in release artifacts.

Only after verification should changes be committed and pushed. Re-run the
secret scan against the final commit before making the repository public.
