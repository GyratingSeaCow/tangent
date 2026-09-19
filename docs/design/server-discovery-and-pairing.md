# Server discovery and pairing — design

Status: proposed. Nothing implemented yet.

Today a user connects a device by typing a URL and pasting an API token. This
document designs discovery ("find my server") and pairing ("prove I'm allowed
in") so a second device can join without the user handling a secret by hand.

Written for every self-hosted user of the public repo, not one person's
network.

---

## 1. Why the token cannot simply be re-fetched

`POST /v1/setup` mints the token on first run and, once set up, deliberately
returns a placeholder rather than the real value
(`server/app/api/setup.py:60`). That is correct and must not change: the
endpoint is unauthenticated, so any device that could reach the server would
otherwise be able to ask for the credential.

So a second device needs a *new* way to obtain a token — one that requires
proof of physical access, not just network access.

---

## 2. Discovery

### The constraint that decides the design

The server ships as a Docker container on a **bridge network** with a published
port (`"8765:8000"`, network mode `server_default` — verified on the reference
deployment). A zeroconf/mDNS advertisement published from inside that container
announces the *container's* IP (e.g. `172.x.x.x`), which no phone on the LAN can
reach. mDNS from a bridged container is a well-known dead end; making it work
requires `network_mode: host`, which does not exist on Docker Desktop for
Windows or macOS.

Requiring host networking would mean telling a large share of users to
restructure their deployment for a convenience feature. Rejected.

### Chosen: client-side subnet sweep, with optional mDNS

The **client** discovers the server, rather than the server advertising itself.

1. Read the device's own IPv4 address and netmask.
2. If the network is a /24 or smaller, probe every host on it; otherwise probe
   only the most common ranges and let the user type an address.
3. For each candidate, `GET http://<ip>:<port>/v1/server/info` with a short
   timeout (750 ms), in parallel batches of ~32.
4. Ports probed: the documented default `8765` first, then `8000`, then any
   port the user has previously used on another network.
5. A host answering **401** is a Tangent server (it exists but we are not
   authenticated). A host answering 200 is a Tangent server that does not
   require auth. Anything else is not ours.

A /24 sweep at 32-way concurrency completes in roughly 1–2 seconds. This works
identically on bridged Docker, host networking, a bare-metal install, or a
Raspberry Pi, and needs no server-side change at all.

**mDNS is an optional enhancement, not the mechanism.** If the server is run
with host networking or natively, it may additionally register
`_tangent._tcp.local`; the client tries mDNS first and falls back to the sweep.
The sweep is what must always work.

### Rejected alternatives

- **Server-side mDNS as the primary mechanism** — fails on the default Docker
  deployment, which is how most users will run it. See above.
- **Broadcast/UDP beacon from the client** — same bridge-network problem in
  reverse: the container never sees LAN broadcast traffic.
- **A cloud rendezvous service** — violates the project's no-third-party rule
  outright.
- **QR code only, no discovery** — still the fastest path when the user is at
  the machine (and is kept as an option), but it does not answer "what is my
  server's address?" for a user who is not.

### Tailscale and other overlay networks

A sweep of the local subnet will not find a server reachable only over
Tailscale. The manual-entry path stays first-class for exactly this reason, and
the discovery sheet says so rather than implying the server is missing.

---

## 3. Pairing (the handshake)

Discovery finds an address. Pairing is how the new device earns a token without
the user copying one.

### Chosen: server-displayed pairing code, client-initiated, short-lived

1. On the new device: Settings → **Find server** → pick a discovered server (or
   type its address) → **Pair**.
2. Client calls `POST /v1/pair/request {device_id, display_name, platform}`.
   No auth. The server creates a pending pairing with a random **6-digit code**,
   a 120-second expiry, and returns an opaque `pair_id` — **not** the code.
3. The server displays the code where only someone with access can see it:
   - in the container logs (`docker compose logs -f tangent-server`),
   - on `GET /v1/pair/pending` (authenticated — an already-paired device can
     show it and approve in one tap),
   - and in the first-run banner.
4. The user enters the 6 digits on the new device. Client calls
   `POST /v1/pair/claim {pair_id, code}`.
5. On match, the server issues a **new token bound to that device_id** and
   marks the pairing consumed. On mismatch it increments a counter; **5 failed
   attempts void the pairing entirely** and it must be restarted.

### Why a code and not "approve on the server"

Approval-only (click OK on the server) is friendlier, but on a headless box the
only approval surface is the log or a second device — which is exactly where
the code already is. The code additionally binds the *specific* request: two
devices pairing simultaneously cannot be confused for one another.

### Security properties, stated plainly

- The code is only useful for 120 seconds and only for one `pair_id`.
- Brute force is bounded: 5 attempts against 10^6 codes, then void.
- Pairing requires **reading the server's output**, i.e. physical or
  administrative access — the property the setup endpoint protects today.
- Tokens become per-device, so a lost tablet can be revoked without
  re-pairing everything else.
- `POST /v1/pair/request` is rate-limited per source IP (10/minute) so it
  cannot be used to spam pending pairings.

### Rejected alternatives

- **Trust-on-first-use with no code** — any device on the LAN could claim a
  token. A guest phone on the same Wi-Fi should not silently gain access to
  every recording.
- **PSK/pre-shared passphrase** — this is just the current token with extra
  steps.
- **TLS client certificates** — correct and unusable for this audience.
- **Bluetooth/NFC pairing** — needs the devices adjacent and adds two platform
  integrations for a case the code already covers.

---

## 4. QR code (the fast path)

When the user *is* at the machine, `GET /v1/pair/qr` (authenticated, or shown
in the first-run banner) renders a QR encoding
`tangent://pair?host=<ip>&port=<port>&pair_id=<id>&code=<code>`. Scanning it
performs discovery and claim in one step.

This is the fastest route and should be offered first in the UI, with sweep
and manual entry beneath it. It is an additive convenience — everything works
without a camera.

---

## 5. API surface

```
POST /v1/pair/request            (no auth, rate-limited)
  → 201 {pair_id, expires_at}

POST /v1/pair/claim              (no auth)
  {pair_id, code}
  → 200 {token, server_name, device_id}
  → 401 wrong code (attempts_remaining)
  → 410 expired or voided

GET  /v1/pair/pending            (auth)
  → 200 [{pair_id, display_name, platform, requested_at, code}]

POST /v1/pair/{pair_id}/approve  (auth)   # approve from an already-paired device
  → 200

GET  /v1/devices                 (auth)   # list, with last_seen
DELETE /v1/devices/{device_id}   (auth)   # revoke one device's token
```

`GET /v1/server/info` gains an **unauthenticated** minimal form so the sweep can
identify a Tangent server without credentials: `{name, version, requires_auth}`
and nothing else. Everything currently on that endpoint stays behind auth.

This overlaps the multi-device sync design's `devices` table — the two share
it, and pairing should land first since sync depends on device identity.

### Schema

```
pairings
  pair_id       TEXT PRIMARY KEY
  code_hash     TEXT NOT NULL      -- hashed, never stored raw
  device_id     TEXT NOT NULL
  display_name  TEXT NOT NULL
  platform      TEXT NOT NULL
  created_at    INTEGER NOT NULL
  expires_at    INTEGER NOT NULL
  attempts      INTEGER NOT NULL DEFAULT 0
  consumed_at   INTEGER NULL
```

`auth` moves from one row to one row **per device** (`device_id`, `token_hash`,
`created_at`, `last_seen_at`, `revoked_at`). The existing single token migrates
as the first device row so current installs keep working untouched.

---

## 6. UI

Settings gains a **Server** section:

- **Find server** — runs the sweep, lists what it found (`name — ip:port`),
  with a spinner and a "searching 192.168.1.0/24…" line so it is obviously
  scanning a range and not phoning home.
- **Enter address manually** — always present, never hidden behind a failure.
- **Scan QR code** — if a camera exists.
- **Paired devices** — list with last-seen, and revoke.

The existing Connect screen stays for manual entry; discovery is additive, so
an upgrade breaks nobody's setup.

---

## 7. Failure modes

| Failure | Behaviour | User sees |
|---|---|---|
| Sweep finds nothing | Offer manual entry and explain overlay networks | "No servers found on this network. If your server is on Tailscale or another VPN, enter its address." |
| Sweep finds several | List all, let the user pick | Server name and address per row |
| Code expired | 410, offer restart | "That code expired — tap Pair again" |
| Wrong code | 401 with remaining attempts | "Incorrect. 3 attempts left." |
| 5 wrong codes | Pairing voided | "Too many attempts. Start pairing again on the server." |
| Server unreachable after pairing | Keep the token, retry | Normal offline behaviour |
| Same device pairs twice | New token, old one revoked | Silent |

---

## 8. Phased plan

1. **Unauthenticated `server_info` minimal form.** *Accepts:* an unauthenticated
   GET returns name/version/requires_auth and no private fields; the
   authenticated form is unchanged.
2. **Per-device tokens.** Migrate `auth` to one row per device; existing token
   becomes device #1. *Accepts:* the current token still authenticates after
   migration; 125 server tests stay green.
3. **Pair request/claim endpoints.** Codes, expiry, attempt limit, hashing.
   *Accepts:* correct code issues a token; wrong code decrements; 6th attempt
   voids; expired pairing returns 410.
4. **Client sweep.** Subnet enumeration, parallel probe, cancellation.
   *Accepts:* finds a server on a /24 in under 3 s; cancels cleanly; never
   blocks the UI thread.
5. **Pairing UI.** Find server → pick → code entry → connected.
   *Accepts:* a fresh device reaches "connected" without typing a token.
6. **Device management.** List and revoke. *Accepts:* revoking a device makes
   its next request 401.
7. **QR fast path.** *Accepts:* scanning pairs in one step.
8. **Optional mDNS.** Server registers `_tangent._tcp.local` when it can; client
   prefers it and falls back to the sweep. *Accepts:* discovery still works with
   mDNS unavailable — which is the default Docker case.

Phases 1–3 are server-side and independently shippable. Phase 4 is the one with
real platform risk (network permissions differ across Android versions).

---

## 9. Open questions

1. **Sweep on cellular.** Should discovery refuse to run when the active
   network is mobile data? Sweeping a carrier-grade NAT range is pointless and
   looks like scanning behaviour. Proposed: Wi-Fi/Ethernet only, with a clear
   message otherwise.
2. **Android permissions.** Probing local addresses may require
   `NEARBY_WIFI_DEVICES` on Android 13+ depending on implementation; needs
   verifying on a real device before Phase 4 is estimated.
3. **Code length.** 6 digits with a 5-attempt cap is ~1 in 200,000 per pairing.
   8 digits is stronger and more annoying to type. 6 seems right for a LAN.
4. **Non-HTTPS.** Pairing over plain HTTP on a LAN means a device already on the
   network could observe a code in flight. Self-signed TLS is hostile to set up.
   Proposed: accept it for LAN, document it, and note that Tailscale users get
   encryption for free.
5. **Server naming.** Discovery lists servers by name; where does that name come
   from — the existing `display_name` from setup, or the machine hostname?
