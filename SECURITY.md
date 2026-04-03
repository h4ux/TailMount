# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in TailMount, please report it responsibly.

**Do not open a public issue.** Instead, email the maintainer or use GitHub's private vulnerability reporting feature:

1. Go to the [Security](../../security/advisories) tab
2. Click "Report a vulnerability"
3. Provide details about the issue

## Security Considerations

### Network

- TailMount runs a **local-only WebDAV server** on `127.0.0.1` with a random port for each mounted server. It is not accessible from the network.
- SSH connections go through the Tailscale WireGuard tunnel. No traffic is sent over the public internet.

### Authentication

- TailMount uses SSH "none" authentication, which relies on Tailscale's WireGuard tunnel identity. No passwords or private keys are stored by the app.
- For non-Tailscale SSH servers, authentication depends on your SSH agent or key configuration.

### Permissions

- The app is **not sandboxed** because it needs to run CLI tools (`tailscale`), create mount points, and bind local server ports.
- An admin password prompt may appear when mounting to `/Volumes/` (owned by root).

### Host Key Validation

- SSH host key validation is currently set to accept all keys (`.acceptAnything()`). This is acceptable within a Tailscale network where connections are already authenticated and encrypted by WireGuard, but should be noted if connecting to non-Tailscale hosts.
