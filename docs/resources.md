# Helpful resources

Last link check: July 14, 2026.

These resources are starting points for research. A project's inclusion here
or in an awesome list is not evidence that it supports reMarkable Paper Pure,
our `aarch64` platform, or our installed OS image. Verify compatibility and
review installation code before making device changes.

## Official documentation

### [reMarkable Developer Mode](https://developer.remarkable.com/documentation/developer-mode)

The primary reference for what developer mode changes, supported USB SSH,
enabling Wi-Fi SSH, writable filesystem behavior, and official recovery
expectations. Prefer this over community instructions when they conflict.

## Community references

### [reMarkable Guide](https://remarkable.guide/)

A community-maintained guide covering device access, software installation,
configuration, technical topics, development, recovery, and related resources.
Check the target device and update date on any procedure before using it.

### [Awesome reMarkable](https://github.com/reHackable/awesome-reMarkable)

A large curated directory of reMarkable applications, launchers, development
libraries, cloud tools, templates, utilities, and interface customizations.
Many projects target older models or firmware, so use it for discovery rather
than as a Paper Pure compatibility list.

## KOReader

### [KOReader source repository](https://github.com/koreader/koreader)

The upstream source, issue tracker, pull requests, release history, and build
information for KOReader. Search here for explicit Paper Pure support and open
compatibility issues before attempting installation.

### [KOReader website](https://koreader.rocks/)

The project's main website, with general information, documentation, download
links, and community entry points.

KOReader supporting other reMarkable models does not prove that its display,
input, suspend/resume, packaging, or launcher integration works on Paper Pure.
Vellum-packaged KOReader `2026.03-r4` has now been installed and interactively
verified on this Paper Pure with reMarkable OS `3.27.3.0`. Treat that as a
specific compatibility result, not a guarantee for other KOReader or OS
versions.

## Paperboard integrations

### [TRMNL Display API](https://docs.trmnl.com/go/private-api/screens)

The official hosted BYOD display contract used by Paperboard's TRMNL provider.
It documents the `access-token` request header and returned `image_url` and
`refresh_rate` fields.

### [Terminus](https://github.com/usetrmnl/terminus)

TRMNL's flagship open-source BYOS server. It supplies dashboard management,
devices, recipes/extensions, playlists, scheduling, and a compatible Display
API. Treat releases below 1.0 as capable of operational changes and review
upgrade notes before moving the pinned deployment.

### [Tailscale userspace networking](https://tailscale.com/docs/concepts/userspace-networking)

Official reference for the no-kernel-route SOCKS5 mode used on the tablet and
by container sidecars.

### [Model Context Protocol TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)

The official SDK used for Paperboard's generic stdio agent server. MCP is only
the local tool transport; relay bearer tokens and Tailscale still enforce the
network/application boundary.

## How to evaluate a new resource

When adding another link, record:

- whether it is official or community maintained;
- its last meaningful update;
- which reMarkable models and OS versions it explicitly supports;
- whether source code and uninstall instructions are available;
- whether it changes the boot chain, root filesystem, stock UI, networking, or
  document storage; and
- any unresolved Paper Pure issues.
