# Security policy and operating rules

Security is a primary project requirement, not a cleanup task after a
customization works. This device permits root access, stores personal data,
and may eventually connect to private services. Every change must therefore
have a clear purpose, a narrow scope, and a recovery path.

## Security posture

Developer mode deliberately weakens parts of the verified boot chain and
enables root SSH access. We cannot make this equivalent to reMarkable's stock
or enterprise-managed security posture. Our goal is to reduce the additional
risk while preserving a useful personal development device.

This Paper Pure should be treated as a **personal experimental device**:

- Do not store confidential employer or customer material on it.
- Do not connect corporate OneDrive or other work accounts without explicit
  organizational approval.
- Do not place broadly privileged API tokens, SSH keys, or cloud credentials
  on the tablet.
- Prefer narrowly scoped, read-only credentials for dashboards and services.

## Required practices

### Access

- Use a dedicated SSH key as documented in [SSH access](ssh.md).
- Keep private keys and generated device passwords out of Git, scripts, shell
  history, chat, and documentation.
- Never expose SSH through router port forwarding or a public listener.
- Keep Wi-Fi SSH limited to a trusted LAN and disable it when it is not needed:

  ```bash
  ssh remarkable rm-ssh-over-wlan off
  ```

- If remote access is added later, use an authenticated private overlay such
  as Tailscale with restrictive ACLs. Do not assume that installing Tailscale
  alone makes every service safe.
- Remember the boundary: the generated local aliases refuse password login,
  but the stock Paper Pure SSH server may still accept its generated root password.
  Server-side key-only authentication is a future hardening task that requires
  separate review and recovery planning.

### Software and scripts

- Require explicit Paper Pure and installed-OS compatibility. A project that
  supports reMarkable 1, reMarkable 2, Paper Pro, or Paper Pro Move is not
  automatically compatible with Paper Pure.
- Read installation and removal code before running it as root.
- Do not use unreviewed `curl | sh`, `wget | sh`, or equivalent installers.
- Prefer pinned releases, checksums, reproducible builds, and upstream source.
- Give custom services the least privilege and narrowest network access they
  need. Do not run as root merely for convenience.
- Bind local-only services to loopback. Do not bind to `0.0.0.0` or `::`
  without an explicit exposure review.

### Device changes

- Begin with read-only discovery and capture the exact device and OS version.
- Back up important data and relevant configuration before each material
  modification.
- Preserve original files rather than overwriting them without a copy.
- Every installed customization needs documented install, verification,
  update, disable, and uninstall procedures.
- Avoid writing to the boot chain, partition table, recovery components, or
  protected root filesystem unless the task specifically requires it and a
  tested recovery procedure exists.
- Prefer files under the persistent home/data partition over modifications to
  the operating-system partition.
- Make one independently testable change at a time.

### Updates

- Record the reMarkable OS version for every compatibility result.
- Before an OS update, review whether installed launchers, hooks, applications,
  and services support the new version.
- Back up custom configuration before updating.
- Assume undocumented hooks and system-file changes may break or disappear
  after an update.
- Re-verify SSH exposure, service state, and application behavior after every
  update.

## Change checklist

Before installing or modifying anything on the tablet, answer:

1. Does the source explicitly support Paper Pure and our OS version?
2. What files, services, partitions, credentials, and network ports change?
3. Has the code or installer been reviewed?
4. What data must be backed up first?
5. How do we verify success without risking user documents?
6. How do we disable and completely remove the change?
7. What is the recovery path if the stock interface no longer starts?

If these questions do not have satisfactory answers, stop and investigate
before running the change.

The prepared Paper Pure recovery path and its WSL-specific limitation are
documented in [Paper Pure recovery](recovery.md).

## If something looks wrong

1. Disconnect the tablet from untrusted networks.
2. Disable Wi-Fi SSH if access is still available.
3. Preserve logs and record the last known change; do not make several new
   changes while guessing.
4. Remove or rotate exposed credentials from another trusted device.
5. Prefer a documented rollback. Use official recovery only after preserving
   any data that can still be recovered.

## Official warning

The [official developer-mode documentation](https://developer.remarkable.com/documentation/developer-mode)
states that developer mode weakens device security and makes the user
responsible for software modifications. Revisit it before boot- or
filesystem-level work.
