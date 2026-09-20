# SPDX-License-Identifier: AGPL-3.0-or-later
"""API token generation, hashing, and FastAPI auth dependency."""

from __future__ import annotations

import hashlib
import secrets
import sqlite3
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from app.db import get_db


def generate_token() -> str:
    """Generate a URL-safe random token (32 bytes → 43 chars)."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """SHA-256 hex digest of a token. Used for at-rest storage."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def require_auth(
    authorization: Annotated[str | None, Header()] = None,
    db: sqlite3.Connection = Depends(get_db),
) -> str:
    """Validate Authorization: Bearer <token> header.

    Returns the display_name stored alongside the token, or raises HTTP 401.
    """
    if not authorization:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing Authorization header",
            headers={"WWW-Authenticate": "Bearer"},
        )

    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authorization header must be 'Bearer <token>'",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = parts[1].strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Empty bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token_hash = hash_token(token)
    row = db.execute(
        "SELECT display_name FROM auth WHERE id = 1 AND token_hash = ?",
        (token_hash,),
    ).fetchone()

    if row is None:
        # Not the primary credential — try the per-device tokens minted by
        # pairing. Revoked rows stay in the table (auditable) but never
        # authenticate.
        row = db.execute(
            "SELECT display_name FROM device_tokens "
            "WHERE token_hash = ? AND revoked_at IS NULL",
            (token_hash,),
        ).fetchone()

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return row["display_name"] or "user"
