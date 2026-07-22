# Agent autonomy and physical boundaries

An agent working with a Paper Pure should aim to complete the full engineering
loop itself: inspect, change, launch, observe, diagnose, verify, roll back, and
document. Asking the owner to perform routine navigation or visual checks is a
fallback, not the default workflow.

## Autonomy rule

Before asking for physical help, an agent should attempt, in order:

1. Read current device state through authenticated SSH.
2. Inspect service logs and process state.
3. Use an existing reviewed command, script, AppLoad API, or Xovi facility.
4. Capture the current display and inspect it locally.
5. Use narrow, reversible input automation when the screen is unlocked.
6. Build a reusable local tool if the capability is missing and the tool can
   be implemented without weakening authentication or opening network access.
7. Document the new path so the next agent does not repeat the manual work.

If physical action remains necessary, group the required actions into one
short request and explain why software cannot safely cross that boundary.

## Good automation

Prefer tools that are:

- reachable only through the existing key-authenticated SSH boundary;
- local and on-demand rather than persistent network services;
- narrowly scoped to one operation;
- explicit about their target device and coordinate system;
- reversible and removable;
- quiet about secrets and private screen contents; and
- accompanied by status, verification, and uninstall instructions.

Examples include screenshot capture, a single-tap injector, deployment
scripts, log collectors, AppLoad launch helpers, and application-specific smoke
tests. Agents are encouraged to create more of these when repeated manual work
would otherwise be required.

Do not create an unauthenticated HTTP control endpoint, listen on a public or
LAN interface, store a passcode, or weaken SSH authentication for convenience.

## Boundaries that remain human

An agent must not bypass the lock screen or request that the owner reveal the
tablet passcode. After a reboot, explicit lock, or automatic lock event, ask the
owner to wake and unlock the device locally. Recovery-mode button sequences,
USB cable changes, and other physical recovery steps also remain human actions.

Disabling the passcode is not the normal development workflow. It changes the
security boundary and should occur only if the owner explicitly chooses that
tradeoff for a dedicated, non-sensitive lab tablet.

## Preparing an agent work session

For a supervised development session:

1. Connect the Paper Pure to power if the session may be long.
2. Unlock it locally once.
3. Temporarily turn off **Auto sleep** in the tablet settings, or choose the
   longest available delay. The exact settings location may change by OS
   release, so confirm it on the device rather than scripting a private config
   mutation.
4. Keep the passcode enabled.
5. Tell the agent the tablet is unlocked and ready; do not provide the code.
6. Re-enable the normal Auto sleep policy when the session ends.

Generic periodic taps are not a safe keep-awake mechanism: a coordinate that
is harmless on one screen may activate a destructive control on another.
`systemd-inhibit` must not be assumed to block the stock UI's own sleep logic
without an explicit compatibility test.

## Current `paperctl` capability

The repository provides an SSH-only bridge:

```bash
scripts/paperctl.sh status
scripts/paperctl.sh screenshot
scripts/paperctl.sh tap X Y
scripts/paperctl.sh swipe X1 Y1 X2 Y2 600
```

The input coordinates use the `1404x1872` logical screen space. If the tablet
is physically rotated, raw framebuffer screenshots may be rotated relative to
that logical space; verify orientation before injecting input. The helper
creates a temporary `/dev/uinput` touchscreen for one tap or one bounded swipe
and then destroys it. It does not run a daemon or open a port.

[Paper Pure Remote](remote.md) can hold that same bounded helper open through
one authenticated SSH child while its loopback-only viewer is running. This
avoids repeating Qt's input-device discovery delay. The process accepts only
tap and swipe records, exits with the viewer, and never becomes a tablet
service or listener.

Paperboard itself is landscape-first and may rotate an `1872x1404` canvas
inside that raw portrait coordinate space. Do not treat Paperboard's visible
landscape coordinates as `paperctl.sh` tap coordinates; capture and inspect a
fresh raw screenshot before any input injection.

Screenshot capture uses the Vellum-packaged `rm-shot` Xovi extension and
message broker. Screenshots default to ignored `captures/`, may contain private
documents, and require a content review before sharing.

The bridge deliberately does not provide passcode entry, arbitrary keystroke
injection, continuous unattended control, or recovery-mode automation.

## End-of-session checklist

1. Exit custom applications and confirm the stock UI is responsive.
2. Confirm `xochitl` is active and the root filesystem is read-only.
3. Remove temporary screenshots from both host and tablet when no longer
   needed.
4. Re-enable Auto sleep if it was relaxed.
5. Lock the tablet.
6. Commit only sanitized, reusable tooling and documentation.

## Mandatory post-change invariant

After every command that changes tablet files, packages, services, or custom
applications, allow the UI to settle and run:

```bash
scripts/verify-appload-runtime.sh --host remarkable-usb
```

Do not batch a second change behind an unverified first change. The check must
confirm that `xochitl` is active through Xovi, the Xovi message broker exists,
Paperboard, PaperTerm, and Chat remain registered under AppLoad, and `/`
remains read-only. A copied bundle or successful backend self-test is not
sufficient. Xovi/AppLoad restarts require physical USB so that Wi-Fi or
Tailscale failure cannot remove the repair path.
