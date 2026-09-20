# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pairing: a second device earns its own bearer token.

The property being protected, same as /v1/setup: obtaining a credential must
require READING THE SERVER'S OUTPUT (logs, an authed device, the first-run
banner), not merely reaching the server over the network. A guest phone on
the same Wi-Fi must not be able to talk its way in.

Flow: the new device POSTs a pairing request and gets back an opaque pair_id
— never the code. The server logs a 6-digit code and shows it to already-
authenticated devices. The user reads the code and types it into the new
device, which claims the pairing and receives a token bound to its device_id.

Codes live 120 seconds, die after 5 wrong attempts, and are stored hashed.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
from collections import deque
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.auth import generate_token, hash_token, require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.models import (
    PairClaim,
    PairClaimResponse,
    PairPendingEntry,
    PairPendingResponse,
    PairRequest,
    PairRequestResponse,
)

router = APIRouter()

log = get_logger(__name__)

#: Seconds a pairing code stays claimable.
PAIR_TTL_SECONDS = 120

#: Wrong-code attempts before the pairing voids itself.
MAX_ATTEMPTS = 5

#: Pairing requests allowed per source IP per minute. Pending pairings are
#: cheap rows, but an unauthenticated endpoint must not be a spam vector.
REQUESTS_PER_MINUTE = 10

#: Sliding window of request timestamps per source IP. In-memory on purpose:
#: a restart clearing the limiter is harmless because a restart also voids
#: every pending pairing it could have been protecting.
_request_log: dict[str, deque[float]] = {}


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, tz=UTC)


def _rate_limited(source: str) -> bool:
    now = time.monotonic()
    window = _request_log.setdefault(source, deque())
    while window and now - window[0] > 60:
        window.popleft()
    if len(window) >= REQUESTS_PER_MINUTE:
        return True
    window.append(now)
    return False


@router.post(
    "/v1/pair/request",
    response_model=PairRequestResponse,
    status_code=status.HTTP_201_CREATED,
)
def pair_request(
    body: PairRequest,
    request: Request,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> PairRequestResponse:
    """Open a pairing. Unauthenticated BY DESIGN — the response contains
    nothing a stranger can use: the code goes to the server's own output,
    never back over this socket."""
    source = request.client.host if request.client else "unknown"
    if _rate_limited(source):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many pairing requests; wait a minute and retry.",
        )

    now = _now_ts()
    pair_id = secrets.token_urlsafe(16)
    # secrets.randbelow, not random: the code IS the credential here.
    code = f"{secrets.randbelow(1_000_000):06d}"

    db.execute(
        """
        INSERT INTO pairings
            (pair_id, code_hash, device_id, display_name, platform,
             created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            pair_id,
            hash_token(code),
            body.device_id,
            body.display_name,
            body.platform,
            now,
            now + PAIR_TTL_SECONDS,
        ),
    )

    # The one place the code is emitted server-side: the container log,
    # readable only by someone with access to the machine. The cache feeds
    # the authenticated pending display; claims verify against the hash.
    _code_cache[pair_id] = code
    log.info(
        "pairing.code_issued",
        code=code,
        device=body.display_name,
        expires_in=PAIR_TTL_SECONDS,
    )
    return PairRequestResponse(
        pair_id=pair_id,
        expires_at=_to_iso(now + PAIR_TTL_SECONDS),
    )


@router.get("/v1/pair/pending", response_model=PairPendingResponse)
def pair_pending(
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> PairPendingResponse:
    """Pending pairings WITH their codes, for an already-paired device to
    display. Authenticated: holding a valid token is exactly the 'physical
    or administrative access' the code is meant to prove.

    Claims verify against the hashed code in the DB. The raw code shown
    here comes from an in-process cache; after a server restart the cache
    is empty, so restart-orphaned pairings are hidden rather than listed
    with a blank code (they expire within 120 s regardless — the container
    log line remains the fallback display).
    """
    now = _now_ts()
    rows = db.execute(
        """
        SELECT pair_id, display_name, platform, created_at
        FROM pairings
        WHERE consumed_at IS NULL AND expires_at > ? AND attempts < ?
        ORDER BY created_at DESC
        """,
        (now, MAX_ATTEMPTS),
    ).fetchall()
    entries = [
        PairPendingEntry(
            pair_id=r["pair_id"],
            display_name=r["display_name"],
            platform=r["platform"],
            requested_at=_to_iso(r["created_at"]),
            code=_code_cache.get(r["pair_id"], ""),
        )
        for r in rows
    ]
    # A pairing whose code this process no longer knows (restart) is
    # unclaimable-by-display; hide it rather than showing a blank code.
    return PairPendingResponse(
        pending=[e for e in entries if e.code]
    )


#: pair_id -> raw code, for the authenticated pending display only. Claims
#: verify against the DB hash, never this cache; a restart empties it, which
#: merely hides (soon-expired) pending codes from the display.
_code_cache: dict[str, str] = {}


@router.post("/v1/pair/claim", response_model=PairClaimResponse)
def pair_claim(
    body: PairClaim,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> PairClaimResponse:
    """Trade pair_id + code for a device-bound token."""
    now = _now_ts()
    row = db.execute(
        "SELECT * FROM pairings WHERE pair_id = ?", (body.pair_id,)
    ).fetchone()

    gone = HTTPException(
        status_code=status.HTTP_410_GONE,
        detail="Pairing expired or voided; start again on the new device.",
    )
    if row is None or row["consumed_at"] is not None:
        raise gone
    if row["expires_at"] <= now or row["attempts"] >= MAX_ATTEMPTS:
        raise gone

    if hash_token(body.code) != row["code_hash"]:
        attempts = row["attempts"] + 1
        db.execute(
            "UPDATE pairings SET attempts = ? WHERE pair_id = ?",
            (attempts, body.pair_id),
        )
        # get_db rolls back when a handler raises; the failed attempt must
        # survive the 401 or brute force gets unlimited tries.
        db.commit()
        if attempts >= MAX_ATTEMPTS:
            _code_cache.pop(body.pair_id, None)
            log.warning("pairing.voided_after_attempts", pair_id=body.pair_id)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "message": "Incorrect code.",
                "attempts_remaining": MAX_ATTEMPTS - attempts,
            },
        )

    # Correct code: consume, mint, and bind. Re-pairing the same device
    # replaces (revokes) its previous token — a device has exactly one.
    raw_token = generate_token()
    db.execute(
        "UPDATE pairings SET consumed_at = ? WHERE pair_id = ?",
        (now, body.pair_id),
    )
    db.execute(
        """
        INSERT INTO device_tokens
            (device_id, token_hash, display_name, created_at, revoked_at)
        VALUES (?, ?, ?, ?, NULL)
        ON CONFLICT(device_id) DO UPDATE SET
            token_hash = excluded.token_hash,
            display_name = excluded.display_name,
            created_at = excluded.created_at,
            revoked_at = NULL
        """,
        (row["device_id"], hash_token(raw_token), row["display_name"], now),
    )
    _code_cache.pop(body.pair_id, None)

    server = db.execute(
        "SELECT display_name FROM auth WHERE id = 1"
    ).fetchone()
    log.info("pairing.claimed", device_id=row["device_id"])
    return PairClaimResponse(
        token=raw_token,
        server_name=(server["display_name"] if server else None) or "Tangent",
        device_id=row["device_id"],
    )


@router.delete("/v1/devices/{device_id}/token")
def revoke_device_token(
    device_id: str,
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> dict:
    """Revoke one device's token (lost tablet). The primary setup token is
    not stored in device_tokens and cannot be revoked here."""
    db.execute(
        "UPDATE device_tokens SET revoked_at = ? WHERE device_id = ?",
        (_now_ts(), device_id),
    )
    log.info("pairing.token_revoked", device_id=device_id)
    return {"revoked": device_id}
