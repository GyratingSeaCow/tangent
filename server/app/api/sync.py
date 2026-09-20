# SPDX-License-Identifier: AGPL-3.0-or-later
"""Multi-device sync: device registry, pull, and push.

The container IS the hub. No third party is involved: a client asks its own
server what changed after checkpoint N, applies it, then pushes what it has.

Merge lives on the CLIENT, deliberately. The server stores document bodies
opaquely, so it never has to understand ink and a client-side document change
does not require a server deploy. What the server owns is the one thing a
client cannot: a single monotonic sequence that every replica can agree on.
"""

from __future__ import annotations

import json
import sqlite3
import time
from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, status

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.models import (
    DeviceListResponse,
    DeviceRegister,
    DeviceResponse,
    SyncChange,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
    SyncPushResult,
)
from app.services.change_log import changes_since, head_seq, record_change

router = APIRouter()

log = get_logger(__name__)

#: Page size for a pull. Bounded so a first sync on a large library streams in
#: pages rather than building one enormous response in memory.
PULL_LIMIT = 500


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=UTC) if ts else None


@router.post(
    "/v1/devices",
    response_model=DeviceResponse,
    status_code=status.HTTP_200_OK,
)
def register_device(
    body: DeviceRegister,
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> DeviceResponse:
    """Register or update a replica. Idempotent by ``device_id``.

    A reinstall yields a new id and simply syncs from 0; the stale row is
    harmless. Registration never resets ``last_seen_seq`` — re-running it must
    not make a device forget its checkpoint.
    """
    db.execute(
        """
        INSERT INTO devices (device_id, display_name, platform, last_seen_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(device_id) DO UPDATE SET
            display_name = excluded.display_name,
            platform = excluded.platform,
            last_seen_at = excluded.last_seen_at
        """,
        (body.device_id, body.display_name, body.platform, _now_ts()),
    )
    row = db.execute(
        "SELECT device_id, display_name, platform, last_seen_seq, last_seen_at "
        "FROM devices WHERE device_id = ?",
        (body.device_id,),
    ).fetchone()
    log.info("sync.device_registered", device_id=body.device_id)
    return DeviceResponse(
        device_id=row["device_id"],
        display_name=row["display_name"],
        platform=row["platform"],
        last_seen_seq=row["last_seen_seq"],
        last_seen_at=_to_iso(row["last_seen_at"]),
    )


@router.get("/v1/devices", response_model=DeviceListResponse)
def list_devices(
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> DeviceListResponse:
    """Every replica the server knows, so a user can see what is syncing."""
    rows = db.execute(
        "SELECT device_id, display_name, platform, last_seen_seq, last_seen_at "
        "FROM devices ORDER BY last_seen_at DESC"
    ).fetchall()
    return DeviceListResponse(
        devices=[
            DeviceResponse(
                device_id=r["device_id"],
                display_name=r["display_name"],
                platform=r["platform"],
                last_seen_seq=r["last_seen_seq"],
                last_seen_at=_to_iso(r["last_seen_at"]),
            )
            for r in rows
        ]
    )


@router.get("/v1/sync/pull", response_model=SyncPullResponse)
def sync_pull(
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    device_id: Annotated[str, Query(min_length=8, max_length=64)],
    since_seq: Annotated[int, Query(ge=0)] = 0,
) -> SyncPullResponse:
    """Changes after ``since_seq``, oldest first.

    The caller's own changes are excluded: a device that re-applied its own
    push would do pointless work, and for an entity it has since edited again
    it would clobber the newer local copy with its own stale echo.

    ``head_seq`` is the checkpoint to store — but only once every change in
    this page has been applied, and only when ``has_more`` is false. Storing it
    early is how a client silently skips changes.
    """
    rows = changes_since(
        db,
        since_seq=since_seq,
        limit=PULL_LIMIT + 1,
        exclude_device_id=device_id,
    )
    has_more = len(rows) > PULL_LIMIT
    page = rows[:PULL_LIMIT]

    # With a full page, the checkpoint is the last row actually returned, not
    # the global head: the client has not seen anything past it yet.
    global_head = head_seq(db)
    checkpoint = page[-1]["seq"] if (has_more and page) else global_head

    return SyncPullResponse(
        changes=[
            SyncChange(
                entity_type=r["entity_type"],
                entity_id=r["entity_id"],
                op=r["op"],
                payload=r["payload"],
                seq=r["seq"],
                device_id=r["device_id"],
            )
            for r in page
        ],
        head_seq=checkpoint,
        has_more=has_more,
    )


def _apply_dump(conn: sqlite3.Connection, change: SyncChange, now: int) -> None:
    """Dump METADATA only. Audio bytes are never pushed through sync; they
    move via upload/download. ``audio_kept`` is the SERVER'S own knowledge of
    whether it holds the file, so a client push never changes it — a device
    that never saw the audio must not make the server forget it has it.

    Fields the peer did not send keep their stored values (an older client
    is a narrower payload, not an eraser).
    """
    if change.op == "delete":
        conn.execute(
            "UPDATE dumps SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, change.entity_id),
        )
        return
    p: dict[str, Any] = change.payload or {}
    existing = conn.execute(
        "SELECT * FROM dumps WHERE id = ?", (change.entity_id,)
    ).fetchone()

    def val(key: str, default: Any = None) -> Any:
        if key in p:
            return p[key]
        if existing is not None:
            return existing[key]
        return default

    conn.execute(
        """
        INSERT INTO dumps
            (id, client_id, created_at, updated_at, mode, duration_seconds,
             title, transcript, meeting_notes, audio_kept, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(id) DO UPDATE SET
            mode = excluded.mode,
            duration_seconds = excluded.duration_seconds,
            title = excluded.title,
            transcript = excluded.transcript,
            meeting_notes = excluded.meeting_notes,
            updated_at = excluded.updated_at,
            deleted_at = NULL
        """,
        (
            change.entity_id,
            p.get("client_id", change.device_id or "sync"),
            int(val("created_at", now)),
            now,
            val("mode", "brain_dump"),
            int(val("duration_seconds", 0)),
            val("title", "Untitled"),
            val("transcript"),
            val("meeting_notes"),
            int(existing["audio_kept"]) if existing is not None else 0,
        ),
    )


def _apply_folder(conn: sqlite3.Connection, change: SyncChange, now: int) -> None:
    """Folders sync by ID only: same-named folders stay separate (user
    decision). Delete tombstones rather than removes, like every entity —
    and filing REMAINS on each notebook row, so a folder deletion arriving
    on a device simply reveals its notebooks as unfiled there."""
    if change.op == "delete":
        conn.execute(
            "UPDATE folders SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, change.entity_id),
        )
        return
    p: dict[str, Any] = change.payload or {}
    conn.execute(
        """
        INSERT INTO folders
            (id, name, created_at, updated_at, deleted_at, origin_device_id)
        VALUES (?, ?, ?, ?, NULL, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            updated_at = excluded.updated_at,
            deleted_at = NULL
        """,
        (
            change.entity_id,
            p.get("name", "Folder"),
            int(p.get("created_at", now)),
            now,
            change.device_id,
        ),
    )


def _apply_document(
    conn: sqlite3.Connection,
    table: str,
    change: SyncChange,
    now: int,
) -> None:
    """Notebooks and notes: body stored opaquely, merge already done client-side."""
    if change.op == "delete":
        conn.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, change.entity_id),
        )
        return
    p: dict[str, Any] = change.payload or {}
    body_column = "doc" if table == "notebooks" else "body"
    body = p.get(body_column)
    encoded = json.dumps(body) if isinstance(body, (dict, list)) else (body or "")
    if table == "notebooks":
        # folder_id: present means "this filing", absent means "keep what is
        # stored" — an older client's narrower payload is not an eraser.
        existing = conn.execute(
            "SELECT folder_id FROM notebooks WHERE id = ?", (change.entity_id,)
        ).fetchone()
        folder_id = (
            p["folder_id"]
            if "folder_id" in p
            else (existing["folder_id"] if existing is not None else None)
        )
        conn.execute(
            """
            INSERT INTO notebooks
                (id, title, doc, created_at, updated_at, deleted_at,
                 origin_device_id, folder_id)
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                doc = excluded.doc,
                updated_at = excluded.updated_at,
                deleted_at = NULL,
                folder_id = excluded.folder_id
            """,
            (
                change.entity_id,
                p.get("title", "Untitled"),
                encoded,
                int(p.get("created_at", now)),
                now,
                change.device_id,
                folder_id,
            ),
        )
        return
    conn.execute(
        f"""
        INSERT INTO {table}
            (id, title, {body_column}, created_at, updated_at, deleted_at,
             origin_device_id)
        VALUES (?, ?, ?, ?, ?, NULL, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            {body_column} = excluded.{body_column},
            updated_at = excluded.updated_at,
            deleted_at = NULL
        """,
        (
            change.entity_id,
            p.get("title", "Untitled"),
            encoded,
            int(p.get("created_at", now)),
            now,
            change.device_id,
        ),
    )


@router.post("/v1/sync/push", response_model=SyncPushResponse)
def sync_push(
    body: SyncPushRequest,
    _: Annotated[str, Depends(require_auth)],
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> SyncPushResponse:
    """Accept a batch of client changes, each stamped with its own ``seq``.

    Results are PER ENTITY. One bad change must not discard a batch of good
    ones: the client clears its dirty flag per entity, so a whole-batch
    rejection would strand work that was perfectly acceptable.
    """
    now = _now_ts()
    results: list[SyncPushResult] = []

    for change in body.changes:
        try:
            publish_payload = change.payload
            if change.entity_type == "dump":
                _apply_dump(db, change, now)
                # Republish what the server now HOLDS, not what the device
                # sent. A device that never had the audio omits audio_kept,
                # and echoing that omission tells every other device the
                # recording is undownloadable while the file sits on disk.
                if change.op != "delete" and change.payload is not None:
                    stored = db.execute(
                        "SELECT audio_kept FROM dumps WHERE id = ?",
                        (change.entity_id,),
                    ).fetchone()
                    if stored is not None:
                        publish_payload = dict(change.payload)
                        publish_payload["audio_kept"] = bool(stored["audio_kept"])
            elif change.entity_type == "notebook":
                _apply_document(db, "notebooks", change, now)
            elif change.entity_type == "folder":
                _apply_folder(db, change, now)
            else:
                _apply_document(db, "notes", change, now)

            seq = record_change(
                db,
                entity_type=change.entity_type,
                entity_id=change.entity_id,
                op=change.op,
                device_id=body.device_id,
                payload=publish_payload,
                now=now,
            )
            results.append(
                SyncPushResult(
                    entity_id=change.entity_id,
                    entity_type=change.entity_type,
                    seq=seq,
                    status="applied",
                )
            )
        except (sqlite3.Error, ValueError, TypeError) as exc:
            # Report and carry on: the rest of the batch is still good.
            log.warning(
                "sync.push_rejected",
                entity_id=change.entity_id,
                entity_type=change.entity_type,
                error=str(exc),
            )
            results.append(
                SyncPushResult(
                    entity_id=change.entity_id,
                    entity_type=change.entity_type,
                    seq=0,
                    status="rejected",
                    reason=str(exc),
                )
            )

    head = head_seq(db)
    db.execute(
        "UPDATE devices SET last_seen_seq = ?, last_seen_at = ? WHERE device_id = ?",
        (head, now, body.device_id),
    )
    log.info(
        "sync.push",
        device_id=body.device_id,
        applied=sum(1 for r in results if r.status == "applied"),
        rejected=sum(1 for r in results if r.status == "rejected"),
    )
    return SyncPushResponse(results=results, head_seq=head)
