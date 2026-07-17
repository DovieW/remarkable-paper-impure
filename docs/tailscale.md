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
the boot-persistent configuration below uses a stable loopback target.

## Boot-persistent operation

The recommended unattended configuration uses a systemd-managed userspace
daemon and a loopback-only Dropbear socket:

```bash
scripts/install-paperboard-tailscale-service.sh --host remarkable-tailnet --dry-run
scripts/install-paperboard-tailscale-service.sh --host remarkable-tailnet
```

The stable loopback-only `127.0.0.1:2222` forwarding target removes the Wi-Fi
DHCP dependency while avoiding reMarkable's interface-bound port 22 sockets.
Tailscale reconnects when the active network changes, while its SOCKS proxy and
Serve configuration remain local to the tablet. Verify with:

```bash
ssh remarkable-tailnet 'systemctl is-active paperboard-tailscale.service paperboard-tailscale-serve.service dropbear-loopback.socket'
```

Disable without removing the units:

```bash
ssh remarkable-tailnet 'systemctl disable --now paperboard-tailscale-serve.service paperboard-tailscale.service dropbear-loopback.socket'
```

Remove the units and return to manual startup:

```bash
scripts/install-paperboard-tailscale-service.sh --host remarkable-tailnet --uninstall
```

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
