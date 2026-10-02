# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for anything you believe is a security
problem — a way to read another user's recordings, bypass pairing, reach the
server without a token, or run code on a device or server.

Instead, use GitHub's private reporting:
**https://github.com/GyratingSeaCow/tangent/security/advisories/new**

Include what you found, how to reproduce it, and which version (app
`Settings → Maintenance & about`, server `GET /v1/server/info/public`). Do not
publish details before the report has been investigated.

## Scope

- The Flutter client (Android, Linux, Windows) under `client/`
- The FastAPI server and its Docker image under `server/`
- The release pipeline under `.github/workflows/`

## Existing controls

- Every device holds its own bearer token, minted only by reading a 6-digit
  code off the server's own output (`docs/design/server-discovery-and-pairing.md`).
  Tokens are stored hashed; a lost device is revoked with one `DELETE`.
- The server binds where you tell it to and is intended to be reached over a
  LAN or a private overlay (Tailscale). It is not designed to be exposed to
  the public internet.
- Release artifacts are built by GitHub Actions from a tag, after the full
  test suites pass, with third-party actions pinned to commit SHAs.

## Supported versions

Only the latest release receives fixes.
