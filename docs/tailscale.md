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

## Tailnet policy

Restrict the tablet identity/tag so it can reach only the relay HTTPS service.
Restrict the relay/agent clients to the minimum identities they need. Node
membership alone should not grant admin API access, SSH access, or broad home
network access.

The repository does not install a persistent tablet boot service. This keeps
the change reversible but means Tailscale must be restarted after a tablet
reboot before relay mode works. Paperboard retains its last snapshot and shows
an offline state until connectivity returns.

Official references:

- [Tailscale userspace networking](https://tailscale.com/docs/concepts/userspace-networking)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Docker configuration parameters](https://tailscale.com/docs/features/containers/docker/docker-params)
