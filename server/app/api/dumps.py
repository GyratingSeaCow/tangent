# SPDX-License-Identifier: AGPL-3.0-or-later
"""Dump CRUD endpoints. Single-user: no row-level auth checks."""

from __future__ import annotations

import os
import sqlite3
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    Header,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)

from app.auth import require_auth
from app.config import get_settings
from app.db import get_db
from app.logging_config import get_logger
from app.models import DumpCreate, DumpListResponse, DumpPatch, DumpResponse
from app.services.change_log import record_change

router = APIRouter()

log = get_logger(__name__)

# Attribution for feed entries made by server-side work (or clients that
# predate the X-Device-Id header). A pull never filters these out, which is
# correct: every device should receive them.
SERVER_DEVICE_ID = "server"


def _publish_dump_change(
    db: sqlite3.Connection,
    dump_id: str,
    device_id: str | None,
    op: str = "upsert",
) -> None:
    """Append this dump's current state to the sync change feed.

    Reads the row AFTER the mutation so the payload is exactly what the
    server now holds — including fields the mutating request didn't carry.
    A delete publishes a bare tombstone.
    """
    author = device_id or SERVER_DEVICE_ID
    if op == "delete":
        record_change(
            db,
            entity_type="dump",
            entity_id=dump_id,
            op="delete",
            device_id=author,
        )
        return
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (dump_id,)
    ).fetchone()
    if row is None:
        return
    record_change(
        db,
        entity_type="dump",
        entity_id=dump_id,
        op="upsert",
        device_id=author,
        payload={
            "client_id": row["client_id"],
            "mode": row["mode"],
            "title": row["title"],
            "transcript": row["transcript"],
            "meeting_notes": row["meeting_notes"],
            "duration_seconds": row["duration_seconds"],
            "audio_kept": bool(row["audio_kept"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        },
    )


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=UTC) if ts else None


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


def _audio_dir() -> Path:
    """Return the configured audio directory, creating it if missing."""
    settings = get_settings()
    p = Path(settings.data_dir) / "audio"
    p.mkdir(parents=True, exist_ok=True)
    return p


@router.post("/v1/dumps/{dump_id}/audio", status_code=status.HTTP_204_NO_CONTENT)
async def upload_audio(
    dump_id: str,
    audio: UploadFile,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    x_device_id: Annotated[str | None, Header()] = None,
) -> Response:
    """Upload the audio file for an existing dump. Idempotent overwrite.

    The file is saved as `data_dir/audio/{dump_id}{ext}` where ext is
    derived from the upload's content-type. Idempotent: re-uploading
    replaces the file.
    """
    row = db.execute(
        "SELECT id, mode FROM dumps WHERE id = ? AND deleted_at IS NULL",
        (dump_id,),
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )
    if row["mode"] == "text_note":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Text notes do not accept audio",
        )

    # Derive extension from content-type or filename; default to .opus.
    ext = ".opus"
    if audio.content_type:
        if "ogg" in audio.content_type:
            ext = ".opus"
        elif "wav" in audio.content_type:
            ext = ".wav"
        elif "mpeg" in audio.content_type or "mp3" in audio.content_type:
            ext = ".mp3"
        elif "mp4" in audio.content_type or "aac" in audio.content_type:
            ext = ".m4a"
    elif audio.filename and "." in audio.filename:
        ext = "." + audio.filename.rsplit(".", 1)[-1].lower()
        if ext not in {".opus", ".wav", ".mp3", ".m4a", ".ogg"}:
            ext = ".opus"

    target = _audio_dir() / f"{dump_id}{ext}"
    target.parent.mkdir(parents=True, exist_ok=True)

    # Stream into a unique file in the destination directory. The canonical
    # path remains absent (or keeps its prior complete contents) until the
    # upload is fully flushed, then os.replace publishes it atomically.
    temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.upload")
    size = 0
    published = False
    try:
        with temporary.open("xb") as f:
            while True:
                chunk = await audio.read(64 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                size += len(chunk)
            if size == 0:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail="Uploaded audio is empty",
                )
            f.flush()
            os.fsync(f.fileno())
        temporary.replace(target)
        published = True
    finally:
        if not published:
            temporary.unlink(missing_ok=True)

    log.info("audio.uploaded", dump_id=dump_id, size=size, path=str(target))
    # The server now verifiably holds this audio: record that and tell the
    # other devices, so their "download from server" affordance can appear.
    db.execute(
        "UPDATE dumps SET audio_kept = 1, updated_at = ? WHERE id = ?",
        (_now_ts(), dump_id),
    )
    _publish_dump_change(db, dump_id, x_device_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/v1/dumps/{dump_id}/audio")
def get_audio(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> Response:
    """Download the audio file for a dump. Returns 404 if missing."""
    row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )

    # Try common extensions.
    for ext in (".opus", ".ogg", ".wav", ".mp3", ".m4a"):
        path = _audio_dir() / f"{dump_id}{ext}"
        if path.exists():
            data = path.read_bytes()
            media = "audio/ogg" if ext in {".opus", ".ogg"} else f"audio/{ext.lstrip('.')}"
            return Response(content=data, media_type=media)

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail=f"No audio file found for dump {dump_id!r}",
    )


def get_audio_path_for_dump(dump_id: str) -> Path | None:
    """Look up the on-disk audio path for a dump (used by transcription jobs)."""
    for ext in (".opus", ".ogg", ".wav", ".mp3", ".m4a"):
        path = _audio_dir() / f"{dump_id}{ext}"
        if path.exists():
            return path
    return None


@router.post("/v1/dumps", response_model=DumpResponse, status_code=status.HTTP_201_CREATED)
def create_dump(
    payload: DumpCreate,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    x_device_id: Annotated[str | None, Header()] = None,
) -> DumpResponse:
    """Create a dump. Idempotent on id (client-generated UUID)."""
    now = _now_ts()
    created_ts = int(payload.created_at.timestamp())

    db.execute(
        """
        INSERT INTO dumps (
            id, client_id, mode, duration_seconds, title,
            created_at, updated_at, transcript, audio_kept
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0)
        ON CONFLICT(id) DO UPDATE SET
            client_id = excluded.client_id,
            mode = excluded.mode,
            duration_seconds = excluded.duration_seconds,
            title = excluded.title,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            deleted_at = NULL
        WHERE dumps.deleted_at IS NOT NULL
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
    _publish_dump_change(db, payload.id, x_device_id)
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
    """One dump with its transcript, mode, and timestamps. 404 once deleted."""
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
    x_device_id: Annotated[str | None, Header()] = None,
) -> DumpResponse:
    """Edit a dump's mutable fields (title, transcript text, done flag). Send only what changes; other fields keep their values. Bumps updated_at so sync picks the edit up."""
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
        _publish_dump_change(db, dump_id, x_device_id)

    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (dump_id,)
    ).fetchone()
    return _row_to_dump(row)


@router.delete("/v1/dumps/{dump_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    x_device_id: Annotated[str | None, Header()] = None,
) -> Response:
    """Soft-delete: the dump leaves every list and sync feed but its row and audio survive server-side until purge. 204 on success, 404 if already gone."""
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
    _publish_dump_change(db, dump_id, x_device_id, op="delete")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
