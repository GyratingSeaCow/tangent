# SPDX-License-Identifier: AGPL-3.0-or-later
"""One-time setup endpoint. No auth required (gated by 'setup already complete' check)."""

from __future__ import annotations

import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import generate_token, hash_token
from app.db import get_db
from app.models import SetupRequest, SetupResponse

router = APIRouter()


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)


@router.post("/v1/setup", response_model=SetupResponse)
def post_setup(
    payload: SetupRequest,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> SetupResponse:
    """Idempotent setup. Returns existing token if already set up; updates display name."""
    row = db.execute(
        "SELECT token_hash, display_name, setup_completed_at FROM auth WHERE id = 1"
    ).fetchone()

    if row is None:
        # First-ever setup: generate token
        raw_token = generate_token()
        new_hash = hash_token(raw_token)
        now = _now_ts()
        db.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at, setup_completed_at) "
            "VALUES (1, ?, ?, ?, ?)",
            (new_hash, payload.display_name, now, now),
        )
        return SetupResponse(
            token=raw_token,
            display_name=payload.display_name,
            setup_completed_at=_to_iso(now),
        )

    # Already set up: update display_name if changed, return a placeholder for token
    db.execute(
        "UPDATE auth SET display_name = ? WHERE id = 1",
        (payload.display_name,),
    )
    return SetupResponse(
        token="<token-issued-on-first-setup-not-shown-again>",
        display_name=payload.display_name,
        setup_completed_at=_to_iso(row["setup_completed_at"]),
    )


def is_setup_complete(db: sqlite3.Connection) -> bool:
    """True if setup has been performed (auth row exists)."""
    row = db.execute("SELECT 1 FROM auth WHERE id = 1 LIMIT 1").fetchone()
    return row is not None