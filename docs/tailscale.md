# Tailscale topology

Tailscale supplies private connectivity, not application authorization.
Paperboard still requires separate client and device bearer tokens.

## Tested WSL/Windows path

```text
Paper Pure Paperboard
  -> loopback SOCKS5 (userspace tailscaled)
  -> private tailnet HTTPS on Windows
  -> Windows Tailscale Serve
  -> WSL loopback relay:8787
```

No Funnel, router port forward, public DNS, kernel tunnel, or tablet-wide route
is required. The tablet binary and its checksum are pinned in
`scripts/install-paperboard-tailscale.sh`; state remains below
`/home/root/.local/share/paperboard/tailscale`.

## Operational commands

```bash
scripts/start-paperboard-tailscale.sh
scripts/stop-paperboard-tailscale.sh
```

Start may print a one-time authentication URL. Open it on a trusted browser and
approve only the expected new node. The process exposes SOCKS5 only at tablet
loopback `127.0.0.1:1055`; Paperboard rejects non-loopback proxy settings.

To make the reviewed screenshot/control SSH boundary reachable without USB,
refresh a private Tailscale Serve TCP forwarder after connecting Wi-Fi:

```bash
scripts/start-paperboard-tailscale.sh --serve-ssh
scripts/configure-paperboard-tailnet-bridge.sh --dry-run
scripts/configure-paperboard-tailnet-bridge.sh
```

This forwards tailnet TCP port 22 to the existing Wi-Fi-bound Dropbear socket.
It does not enable Funnel. The relay profile continues to require the restricted
control key and verifies the same host key pinned over physical USB. Run the
start command again if the tablet joins a different Wi-Fi network, because the
local forwarding target can change. This caveat applies only to manual mode;
the lifecycle-managed configuration below uses a stable loopback target.

## Xovi-lifecycle-persistent operation

The tablet root filesystem is read-only and `/etc` is backed by a volatile
overlay. Custom units placed in `/etc/systemd/system` can therefore vanish when
the runtime is rebuilt. The recommended configuration stores reviewed helpers
in encrypted `/home`, starts transient systemd services through a persistent
Xovi `post-start` hook, and checks them every minute:

```bash
scripts/install-paperboard-tailscale-service.sh --host remarkable-usb --dry-run
scripts/install-paperboard-tailscale-service.sh --host remarkable-usb
```

The stable loopback-only `127.0.0.1:2222` forwarding target removes the Wi-Fi
DHCP dependency while avoiding reMarkable's interface-bound port 22 sockets.
Tailscale reconnects when the active network changes. If the daemon, loopback
SSH listener, or Serve route fails, the health timer repairs the private route
within about one minute. Verify with:

```bash
scripts/verify-appload-runtime.sh --host remarkable-tailnet --wait 75
```

Remove the hook and transient services and return to manual startup:

```bash
scripts/install-paperboard-tailscale-service.sh --host remarkable-tailnet --uninstall
```

This is not a claim of unattended full-reboot persistence. On the tested Paper
Pure stack, Xovi remains deliberately `tethered`: after a real tablet reboot,
the owner may still need USB to start Xovi. Once Xovi starts, the hook restores
private SSH automatically. Do not add boot integration without separately
reviewing it against the current firmware and recovery path.

## Tailnet policy

Restrict the tablet identity/tag so it can reach only the relay HTTPS service.
Restrict the relay/agent clients to the minimum identities they need. Node
membership alone should not grant admin API access, SSH access, or broad home
network access.

The service is optional and reversible. Paperboard retains its last snapshot
and shows an offline state whenever private connectivity is unavailable.

Official references:

- [Tailscale userspace networking](https://tailscale.com/docs/concepts/userspace-networking)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Docker configuration parameters](https://tailscale.com/docs/features/containers/docker/docker-params)
