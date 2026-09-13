# SPDX-License-Identifier: AGPL-3.0-or-later
"""Dump CRUD endpoints. Single-user: no row-level auth checks."""

from __future__ import annotations

import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import require_auth
from app.db import get_db
from app.models import DumpCreate, DumpListResponse, DumpPatch, DumpResponse

router = APIRouter()


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None


def _row_to_dump(row: sqlite3.Row) -> DumpResponse:
    return DumpResponse(
        id=row["id"],
        mode=row["mode"],
        title=row["title"],
        transcript=row["transcript"],
        duration_seconds=row["duration_seconds"],
        created_at=_to_iso(row["created_at"]),
        updated_at=_to_iso(row["updated_at"]),
    )


@router.post("/v1/dumps", response_model=DumpResponse, status_code=status.HTTP_201_CREATED)
def create_dump(
    payload: DumpCreate,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    """Create a dump. Idempotent on id (client-generated UUID)."""
    now = _now_ts()
    created_ts = int(payload.created_at.timestamp())

    # Idempotency: if exists, return as-is
    existing = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (payload.id,)
    ).fetchone()
    if existing:
        return _row_to_dump(existing)

    db.execute(
        """
        INSERT INTO dumps (
            id, client_id, mode, duration_seconds, title,
            created_at, updated_at, transcript, audio_kept
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0)
        """,
        (
            payload.id,
            "single-user",
            payload.mode,
            payload.duration_seconds,
            payload.title,
            created_ts,
            now,
        ),
    )
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (payload.id,)
    ).fetchone()
    return _row_to_dump(row)


@router.get("/v1/dumps", response_model=DumpListResponse)
def list_dumps(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> DumpListResponse:
    """List dumps, newest first."""
    total = db.execute(
        "SELECT COUNT(*) AS c FROM dumps WHERE deleted_at IS NULL"
    ).fetchone()["c"]

    rows = db.execute(
        """
        SELECT * FROM dumps WHERE deleted_at IS NULL
        ORDER BY created_at DESC LIMIT ? OFFSET ?
        """,
        (limit, offset),
    ).fetchall()

    return DumpListResponse(
        dumps=[_row_to_dump(r) for r in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.get("/v1/dumps/{dump_id}", response_model=DumpResponse)
def get_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )
    return _row_to_dump(row)


@router.patch("/v1/dumps/{dump_id}", response_model=DumpResponse)
def patch_dump(
    dump_id: str,
    payload: DumpPatch,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )

    updates: list[str] = []
    params: list[object] = []
    if payload.title is not None:
        updates.append("title = ?")
        params.append(payload.title)
    if updates:
        updates.append("updated_at = ?")
        params.append(_now_ts())
        params.append(dump_id)
        db.execute(f"UPDATE dumps SET {', '.join(updates)} WHERE id = ?", params)

    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (dump_id,)
    ).fetchone()
    return _row_to_dump(row)


@router.delete("/v1/dumps/{dump_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> Response:
    row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )
    db.execute(
        "UPDATE dumps SET deleted_at = ? WHERE id = ?", (_now_ts(), dump_id)
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)