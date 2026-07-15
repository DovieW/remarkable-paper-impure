# Paperboard

Paperboard is this repository's first custom Paper Pure application: a quiet,
full-screen e-ink dashboard rendered as a native AppLoad QML frontend while
preserving the stock reMarkable interface.

## Current milestone

Version `0.2.0` adds an on-demand HTTPS image backend to the offline display
proof. It stores no credentials in this repository, installs no system service,
and does not modify the protected root filesystem. The backend exists only
while Paperboard is open and AppLoad terminates it on return.

It verifies:

- resource compilation with the official Paper Pure (`tatsu`) SDK;
- Qt Quick rendering inside AppLoad's managed surface;
- native touch delivery;
- a deliberate full-screen e-ink layout;
- local refresh interaction;
- verified HTTPS transport through libcurl and the device CA bundle;
- decode-before-acceptance and atomic last-good caching; and
- clean return to the stock interface.

The initial application is constrained to Paper Pure and reMarkable OS `3.27.x`
until later versions are tested explicitly.

## Build

Install the pinned official SDK outside the repository:

```bash
scripts/setup-paperboard-sdk.sh --dry-run
scripts/setup-paperboard-sdk.sh
```

The setup script downloads the SDK published for reMarkable OS `3.27.0.97` and
the `tatsu` platform, verifies its recorded SHA-256 digest, and installs it to
`~/.local/share/remarkable-sdk/tatsu-3.27.0.97` by default.

Build Paperboard:

```bash
scripts/build-paperboard.sh --clean
```

Build output belongs under ignored `build/paperboard-tatsu/`.

## Deploy

Verify the target and planned files without changing the tablet:

```bash
scripts/deploy-paperboard.sh --dry-run
```

Deploy the built backend, resource bundle, and manifest:

```bash
scripts/deploy-paperboard.sh
```

Deployment verifies the platform, architecture, and OS family; stages files
under the persistent home partition; atomically replaces the AppLoad directory;
and retains the immediately previous deployment outside AppLoad under
`/home/root/.local/share/paperboard/deployment-previous`.

Use **Reload** in AppLoad after normal deployment. This avoids restarting the
stock UI and preserves an unlocked development session. If AppLoad cannot
reload normally, deploy with `--restart-xovi`; save open work first and allow
at least 15 seconds for the UI to settle afterward.

## On-device paths

```text
/home/root/xovi/exthome/appload/paperboard/
├── manifest.json
├── resources.rcc
└── backend/
    └── entry
```

The QML frontend is loaded by AppLoad into the stock Qt process. It does not
start a second display process, stop `xochitl`, or directly take ownership of
the framebuffer. AppLoad starts the small ARM64 backend on demand and connects
it over a temporary Unix socket.

## Configure a dashboard

Put one HTTPS URL in a private file outside this repository, then transfer it
without printing it:

```bash
printf '%s\n' 'https://dashboard.example/image.png' > ~/paperboard-url
chmod 600 ~/paperboard-url
scripts/configure-paperboard.sh --from-file ~/paperboard-url --dry-run
scripts/configure-paperboard.sh --from-file ~/paperboard-url
```

The script writes `/home/root/.config/paperboard/config` as mode `0600`.
Paperboard refuses symlinked, non-root-owned, or group/world-readable config;
non-HTTPS URLs; URL user info; images over 8 MiB; non-PNG data; unsafe image
dimensions; transport errors; and Qt decode failures. HTTPS redirects are
limited to three and may only remain on HTTPS. Peer and hostname verification
use `/etc/ssl/certs/ca-certificates.crt`.

Signed URLs are credentials. Keep their source file outside the repository,
avoid shell history, scope them read-only, and give them a short lifetime.
Remove the on-device configuration with:

```bash
scripts/configure-paperboard.sh --remove
```

The private last-good image is stored at
`/home/root/.local/share/paperboard/dashboard.png`. A failed refresh never
replaces it. Removing configuration intentionally leaves that offline cache;
delete it separately if its content is sensitive.

## Remove or roll back

Exit Paperboard first, then preview and remove only the AppLoad bundle:

```bash
scripts/remove-paperboard.sh --dry-run
scripts/remove-paperboard.sh
```

Add `--purge-data` to delete its private configuration, last-good cache, and
retained deployment. A normal redeploy keeps the immediately previous bundle
at `/home/root/.local/share/paperboard/deployment-previous`; restore it only
while Paperboard is closed, then use **Reload** in AppLoad.

## Verification checklist

1. Paperboard appears in AppLoad.
2. It launches fullscreen without restarting the tablet.
3. The complete composition is visible with no clipping or rotation error.
4. With no config, **REFRESH PROOF** fails closed without creating a cache.
5. With a valid config, refresh displays a decoded PNG and creates a mode
   `0600` last-good image.
6. A bad response leaves the last-good SHA-256 unchanged.
7. **RETURN** exits, restores AppLoad, and terminates the backend.
8. `scripts/status.sh` still reports `xovi-appload` and a read-only root mount.

## Agent-side screen control

The optional `paperctl` helper lets an authenticated SSH operator capture the
current screen and inject a single tap using screenshot coordinates. It adds no
listener or background service and cannot bypass the tablet passcode.

Install the reviewed Vellum screenshot extension and build/deploy the tap
helper before first use:

```bash
ssh remarkable-usb '/home/root/.vellum/bin/vellum add --simulate rm-shot'
ssh remarkable-usb '/home/root/.vellum/bin/vellum add rm-shot && /home/root/xovi/start'
scripts/build-paperctl.sh
scripts/deploy-paperctl.sh
```

Then:

```bash
scripts/paperctl.sh status
scripts/paperctl.sh screenshot
scripts/paperctl.sh tap 700 900
```

Screenshots are written under ignored `captures/` by default and may contain
private documents. Never commit them without an explicit content review.
The current screenshot extension can render unchanged regions as black after
a partial e-ink update; relaunch the foreground app for a full-frame proof.
The tablet must already be unlocked; `paperctl` intentionally cannot enter or
bypass its passcode. See [Agent autonomy](agent-autonomy.md) for session setup
and the end-of-session checklist.

## Next milestone

Add a configurable presentation policy for native-resolution monochrome
dashboard images, then implement TRMNL protocol compatibility. Scheduled
background refresh remains deliberately deferred until suspend, battery, and
network behavior are measured safely.

## Primary references

- [Official reMarkable SDK documentation](https://developer.remarkable.com/documentation/sdk)
- [Official Qt Quick application guide](https://developer.remarkable.com/documentation/qt_epaper)
- [AppLoad](https://github.com/asivery/rm-appload)
- [Vellum packages](https://github.com/vellum-dev/vellum)
