# Release procedure

Paperboard uses a manual release gate because deployment reaches a rooted
physical device and depends on an exact firmware compatibility record.

```bash
scripts/release-check.sh
```

The gate performs shell syntax validation, SSH bootstrap and TrueNAS lifecycle
dry-runs, TypeScript build/type checks, all tests, QML bundle build,
operation-registry and custom-app Compose validation, diff whitespace checks,
and non-printing tracked/history secret and private-tailnet scans.

Then, with USB preferred:

```bash
scripts/status.sh --host remarkable-usb
scripts/backup.sh --host remarkable-usb --dry-run
scripts/backup.sh --host remarkable-usb
scripts/deploy-paperboard.sh --host remarkable-usb --dry-run
scripts/deploy-paperboard.sh --host remarkable-usb
scripts/paperboard-doctor.sh --host remarkable-usb
```

Deployment restarts the Xovi-managed UI services so AppLoad loads the new QML
resources, waits for them to settle, and then launches Paperboard. This does
not reboot the tablet, but it briefly interrupts the stock UI. Reserve
`--no-restart-xovi` for a verified backend-only build.

Verify Dashboard queue-only behavior, Screen foreground/presentation and
history, Reader address/search navigation, links, back/forward/reload,
bookmark persistence, and rejection of a private URL, plus tap-to-toggle
chrome, one-hour handoff configuration, Exit, screenshot, and rollback
metadata. Capture no confidential display in release artifacts.

Only after verification should changes be committed and pushed. Re-run the
secret scan against the final commit before making the repository public.
