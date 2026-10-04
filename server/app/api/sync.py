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
from app.services import ocr_worker
from app.services.change_log import changes_since, head_seq, record_change

router = APIRouter()

log = get_logger(__name__)

#: Page size for a pull. Bounded so a first sync on a large library streams in
#: pages rather than building one enormous response in memory.
PULL_LIMIT = 500

#: Folder columns that exist only on the server (v1.30 Google list mapping).
#: Never written from a device payload, never republished in the feed.
FOLDER_SERVER_ONLY_FIELDS = frozenset({"google_tasklist_id"})

#: Calendar columns authored only by the Google worker. Device pushes cannot
#: set or clear these, but the canonical pull projection includes them.
CALENDAR_SERVER_ONLY_FIELDS = frozenset(
    {"google_event_id", "google_html_link", "google_updated"}
)


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
    include_ink_index: Annotated[bool, Query()] = False,
) -> SyncPullResponse:
    """Changes after ``since_seq``, oldest first.

    The caller's own changes are excluded: a device that re-applied its own
    push would do pointless work, and for an entity it has since edited again
    it would clobber the newer local copy with its own stale echo.

    ``head_seq`` is the checkpoint to store — but only once every change in
    this page has been applied, and only when ``has_more`` is false. Storing it
    early is how a client silently skips changes.

    ``include_ink_index`` is the additive opt-in for the handwriting-search
    entity. Old clients never send it and never see ink_index rows — but their
    checkpoint still advances past the filtered entries, or they would re-pull
    the same page forever. An ink_index upsert payload is built AT PULL TIME
    from the live table (replace-set semantics: the client drops that
    notebook's rows and inserts these), so a stale log entry can never carry
    stale rows.
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

    changes: list[SyncChange] = []
    for r in page:
        payload = r["payload"]
        if r["entity_type"] == "ink_index":
            if not include_ink_index:
                continue  # legacy client: additive entity stays invisible
            if r["op"] == "upsert":
                payload = _ink_index_replace_set(db, r["entity_id"])
        changes.append(
            SyncChange(
                entity_type=r["entity_type"],
                entity_id=r["entity_id"],
                op=r["op"],
                payload=payload,
                seq=r["seq"],
                device_id=r["device_id"],
            )
        )

    return SyncPullResponse(
        changes=changes,
        head_seq=checkpoint,
        has_more=has_more,
    )


def _ink_index_replace_set(
    conn: sqlite3.Connection, notebook_id: str
) -> dict[str, Any]:
    """The notebook's full current index — the replace-set a client applies."""
    rows = conn.execute(
        "SELECT id, line_id, word_text, bbox_json, stroke_ids_json, model, "
        "indexed_at FROM ink_index WHERE notebook_id = ? ORDER BY id",
        (notebook_id,),
    ).fetchall()
    return {
        "notebook_id": notebook_id,
        "rows": [
            {
                "id": r["id"],
                "line_id": r["line_id"],
                "word_text": r["word_text"],
                "bbox": json.loads(r["bbox_json"]),
                "stroke_ids": json.loads(r["stroke_ids_json"]),
                "model": r["model"],
                "indexed_at": r["indexed_at"],
            }
            for r in rows
        ],
    }


def _apply_dump(conn: sqlite3.Connection, change: SyncChange, now: int) -> None:
    """Dump METADATA only. Audio bytes are never pushed through sync; they
    move via upload/download. ``audio_kept`` is the SERVER'S own knowledge of
    whether it holds the file, so a client push never changes it — a device
    that never saw the audio must not make the server forget it has it.

    Fields the peer did not send keep their stored values (an older client
    is a narrower payload, not an eraser).

    ``summary``/``summary_model``/``summarized_at`` are server-generated and
    NEVER written from a client payload — deliberately absent from both the
    INSERT columns and the UPDATE SET below. Absence is not an eraser, an
    explicit null is not an eraser, and a client-sent value is not an
    authority: whatever the client sends, the stored summary stands.
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

    # folder_id: present means "this filing", absent means "keep what is
    # stored" (the notebooks contract — an older client is a narrower
    # payload, not an eraser). A push that CHANGES the filing also retires
    # the server's auto-file markers: the user took control (an Undo is
    # exactly such a push), so the chip must disappear everywhere.
    filing_changed = "folder_id" in p and (
        existing is None or p["folder_id"] != existing["folder_id"]
    )
    auto_filed_at = (
        None
        if filing_changed or existing is None
        else existing["auto_filed_at"]
    )
    auto_file_prev_folder_id = (
        None
        if filing_changed or existing is None
        else existing["auto_file_prev_folder_id"]
    )
    conn.execute(
        """
        INSERT INTO dumps
            (id, client_id, created_at, updated_at, mode, duration_seconds,
             title, transcript, meeting_notes, speaker_names, audio_kept,
             folder_id, auto_filed_at, auto_file_prev_folder_id, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(id) DO UPDATE SET
            mode = excluded.mode,
            duration_seconds = excluded.duration_seconds,
            title = excluded.title,
            transcript = excluded.transcript,
            meeting_notes = excluded.meeting_notes,
            speaker_names = excluded.speaker_names,
            folder_id = excluded.folder_id,
            auto_filed_at = excluded.auto_filed_at,
            auto_file_prev_folder_id = excluded.auto_file_prev_folder_id,
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
            val("speaker_names"),
            int(existing["audio_kept"]) if existing is not None else 0,
            val("folder_id"),
            auto_filed_at,
            auto_file_prev_folder_id,
        ),
    )

    if "speaker_names" in p:
        _teach_from_rename(
            conn,
            change.entity_id,
            existing["speaker_names"] if existing is not None else None,
            p["speaker_names"],
            existing["speaker_embeddings"] if existing is not None else None,
        )


def _teach_from_rename(
    conn: sqlite3.Connection,
    dump_id: str,
    stored_map: str | None,
    new_map: str | None,
    embeddings_json: str | None,
) -> list[str]:
    """Synchronise user-taught label/name pairs and their provenance ledger."""
    from app.services.voice_book import normalise, teach, unteach  # noqa: PLC0415

    if not embeddings_json:
        return []
    try:
        new = json.loads(new_map) if new_map else {}
        old = json.loads(stored_map) if stored_map else {}
        embeddings = json.loads(embeddings_json) or {}
    except (TypeError, ValueError):
        return []
    taught: list[str] = []
    untaught: list[str] = []
    for label in dict.fromkeys((*old, *new)):
        clean = (new.get(label) or "").strip()
        old_clean = (old.get(label) or "").strip()
        if old_clean == clean:
            continue
        taught_row = conn.execute(
            "SELECT name, embedding FROM voice_book_samples "
            "WHERE dump_id = ? AND label = ?",
            (dump_id, label),
        ).fetchone()
        if taught_row is not None:
            try:
                if unteach(conn, taught_row[0], json.loads(taught_row[1])):
                    untaught.append(taught_row[0])
            except (TypeError, ValueError) as exc:
                log.warning(
                    "voice_book.unteach_skipped",
                    name=taught_row[0],
                    error=str(exc),
                )
        conn.execute(
            "DELETE FROM voice_book_samples WHERE dump_id = ? AND label = ?",
            (dump_id, label),
        )
        if not clean or label not in embeddings:
            continue
        try:
            teach(conn, clean, embeddings[label])
        except (TypeError, ValueError) as exc:
            log.warning("voice_book.teach_skipped", name=clean, error=str(exc))
            continue
        conn.execute(
            "INSERT INTO voice_book_samples (dump_id, label, name, embedding) "
            "VALUES (?, ?, ?, ?)",
            (dump_id, label, clean, json.dumps(normalise(embeddings[label]))),
        )
        taught.append(clean)
    if untaught:
        log.info("voice_book.untaught", names=untaught)
    if taught:
        log.info("voice_book.taught", names=taught)
    return taught


def _apply_folder(conn: sqlite3.Connection, change: SyncChange, now: int) -> None:
    """Folders sync by ID only: same-named folders stay separate (user
    decision). Delete tombstones rather than removes, like every entity —
    and filing REMAINS on each notebook row, so a folder deletion arriving
    on a device simply reveals its notebooks as unfiled there.

    ``google_tasklist_id`` is deliberately absent from the upsert column
    list: a device re-sending a folder must not clear its Google list."""
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


def _iso_instant(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"todo {field} must be an ISO instant")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"todo {field} must be an ISO instant") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"todo {field} must include a timezone")
    return value


def _instant_value(value: str) -> datetime:
    """Normalize equivalent ISO spellings/offsets before comparing instants."""
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _todo_sync_payload(row: sqlite3.Row) -> dict[str, Any]:
    """Public todo projection; Google IDs/timestamps are server-only."""
    return {
        "id": row["id"],
        "text": row["text"],
        "done_at": row["done_at"],
        "due_date": row["due_date"],
        "source": row["source"],
        "source_ref": row["source_ref"],
        "folder_id": row["folder_id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "deleted_at": row["deleted_at"],
    }


def _apply_todo(
    conn: sqlite3.Connection, change: SyncChange, now: int
) -> tuple[bool, dict[str, Any] | None]:
    """Apply one todo, preserving omitted nullable fields and dropping stale writes."""
    existing = conn.execute(
        "SELECT * FROM todos WHERE id = ?", (change.entity_id,)
    ).fetchone()
    p: dict[str, Any] = change.payload or {}

    if change.op == "delete":
        incoming_updated = p.get("updated_at", datetime.fromtimestamp(now, tz=UTC).isoformat())
        incoming_updated = _iso_instant(incoming_updated, "updated_at")
        if existing is not None and _instant_value(incoming_updated) <= _instant_value(
            existing["updated_at"]
        ):
            return False, None
        if existing is not None:
            deleted_at = p.get("deleted_at", incoming_updated)
            _iso_instant(deleted_at, "deleted_at")
            conn.execute(
                "UPDATE todos SET updated_at = ?, deleted_at = ? WHERE id = ?",
                (incoming_updated, deleted_at, change.entity_id),
            )
        return True, None

    if change.payload is None:
        raise ValueError("todo upsert requires a payload")
    for field in ("text", "created_at", "updated_at"):
        if field not in p:
            raise ValueError(f"todo upsert requires {field}")
    if not isinstance(p["text"], str) or not p["text"].strip():
        raise ValueError("todo text must be a non-empty string")
    created_at = _iso_instant(p["created_at"], "created_at")
    updated_at = _iso_instant(p["updated_at"], "updated_at")
    if existing is not None and _instant_value(updated_at) <= _instant_value(
        existing["updated_at"]
    ):
        return False, None

    def nullable(field: str) -> str | None:
        value = p[field] if field in p else (existing[field] if existing is not None else None)
        if value is not None and not isinstance(value, str):
            raise ValueError(f"todo {field} must be a string or null")
        return value

    done_at = nullable("done_at")
    if done_at is not None:
        _iso_instant(done_at, "done_at")
    due_date = nullable("due_date")
    if due_date is not None:
        try:
            if datetime.strptime(due_date, "%Y-%m-%d").strftime("%Y-%m-%d") != due_date:
                raise ValueError
        except ValueError as exc:
            raise ValueError("todo due_date must be YYYY-MM-DD or null") from exc
    source_ref = nullable("source_ref")
    folder_id = nullable("folder_id")
    deleted_at = nullable("deleted_at")
    if deleted_at is not None:
        _iso_instant(deleted_at, "deleted_at")
    source = p.get("source", existing["source"] if existing is not None else "manual")
    if not isinstance(source, str) or not source:
        raise ValueError("todo source must be a non-empty string")

    conn.execute(
        """
        INSERT INTO todos
            (id, text, done_at, due_date, source, source_ref, folder_id,
             created_at, updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            text = excluded.text, done_at = excluded.done_at,
            due_date = excluded.due_date, source = excluded.source,
            source_ref = excluded.source_ref, folder_id = excluded.folder_id,
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at
        """,
        (change.entity_id, p["text"], done_at, due_date, source, source_ref,
         folder_id, created_at, updated_at, deleted_at),
    )
    stored = conn.execute("SELECT * FROM todos WHERE id = ?", (change.entity_id,)).fetchone()
    return True, _todo_sync_payload(stored)


def _calendar_event_payload(row: sqlite3.Row) -> dict[str, Any]:
    """Canonical device projection, mapping SQL ``end_`` to JSON ``end``."""
    return {
        "id": row["id"],
        "title": row["title"],
        "start": row["start"],
        "end": row["end_"],
        "all_day": row["all_day"],
        "time_zone": row["time_zone"],
        "needs_date": row["needs_date"],
        "source": row["source"],
        "source_ref": row["source_ref"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "deleted_at": row["deleted_at"],
        "google_event_id": row["google_event_id"],
        "google_html_link": row["google_html_link"],
        "google_updated": row["google_updated"],
    }


def _apply_calendar_event(
    conn: sqlite3.Connection, change: SyncChange, now: int
) -> tuple[bool, dict[str, Any] | None]:
    """Apply one event with LWW semantics and server-only field projection."""
    existing = conn.execute(
        "SELECT * FROM calendar_events WHERE id = ?", (change.entity_id,)
    ).fetchone()
    p: dict[str, Any] = change.payload or {}

    if change.op == "delete":
        incoming_updated = p.get(
            "updated_at", datetime.fromtimestamp(now, tz=UTC).isoformat()
        )
        incoming_updated = _iso_instant(incoming_updated, "updated_at")
        if existing is not None and _instant_value(incoming_updated) <= _instant_value(
            existing["updated_at"]
        ):
            return False, None
        if existing is not None:
            deleted_at = p.get("deleted_at", incoming_updated)
            _iso_instant(deleted_at, "deleted_at")
            conn.execute(
                "UPDATE calendar_events SET updated_at = ?, deleted_at = ? WHERE id = ?",
                (incoming_updated, deleted_at, change.entity_id),
            )
        return True, None

    if change.payload is None:
        raise ValueError("calendar_event upsert requires a payload")
    required = ("title", "start", "end", "time_zone", "created_at", "updated_at")
    for field in required:
        if field not in p:
            raise ValueError(f"calendar_event upsert requires {field}")
    for field in ("title", "start", "end", "time_zone"):
        if not isinstance(p[field], str) or not p[field].strip():
            raise ValueError(f"calendar_event {field} must be a non-empty string")
    created_at = _iso_instant(p["created_at"], "created_at")
    updated_at = _iso_instant(p["updated_at"], "updated_at")
    if existing is not None and _instant_value(updated_at) <= _instant_value(
        existing["updated_at"]
    ):
        return False, None

    def nullable(field: str) -> str | None:
        value = p[field] if field in p else (existing[field] if existing is not None else None)
        if value is not None and not isinstance(value, str):
            raise ValueError(f"calendar_event {field} must be a string or null")
        return value

    deleted_at = nullable("deleted_at")
    if deleted_at is not None:
        _iso_instant(deleted_at, "deleted_at")
    source_ref = nullable("source_ref")
    source = p.get("source", existing["source"] if existing is not None else "voice")
    if not isinstance(source, str) or not source:
        raise ValueError("calendar_event source must be a non-empty string")
    all_day = int(bool(p.get("all_day", existing["all_day"] if existing else 1)))
    needs_date = int(bool(p.get("needs_date", existing["needs_date"] if existing else 0)))

    conn.execute(
        """
        INSERT INTO calendar_events
            (id, title, start, end_, all_day, time_zone, needs_date, source,
             source_ref, created_at, updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, start = excluded.start, end_ = excluded.end_,
            all_day = excluded.all_day, time_zone = excluded.time_zone,
            needs_date = excluded.needs_date, source = excluded.source,
            source_ref = excluded.source_ref, updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at
        """,
        (
            change.entity_id, p["title"], p["start"], p["end"], all_day,
            p["time_zone"], needs_date, source, source_ref, created_at,
            updated_at, deleted_at,
        ),
    )
    stored = conn.execute(
        "SELECT * FROM calendar_events WHERE id = ?", (change.entity_id,)
    ).fetchone()
    return True, _calendar_event_payload(stored)


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
        # ink follows the same rule: the client pushes 'doc' and 'ink' as
        # SEPARATE fields, and a payload without ink (title edit, old app)
        # must not erase the strokes the server already holds.
        existing = conn.execute(
            "SELECT folder_id, ink, password_hash, password_salt, "
            "password_iterations, password_hash_prev FROM notebooks WHERE id = ?",
            (change.entity_id,),
        ).fetchone()
        folder_id = (
            p["folder_id"]
            if "folder_id" in p
            else (existing["folder_id"] if existing is not None else None)
        )
        if "ink" in p:
            ink_val = p["ink"]
            ink = (
                json.dumps(ink_val)
                if isinstance(ink_val, (dict, list))
                else ink_val
            )
        else:
            ink = existing["ink"] if existing is not None else None
        # password_hash_prev is both transition proof and a one-generation
        # tombstone. Missing metadata is an old peer and preserves the state.
        if "password_hash" not in p:
            password_hash = existing["password_hash"] if existing is not None else None
            password_salt = existing["password_salt"] if existing is not None else None
            password_iterations = (
                existing["password_iterations"] if existing is not None else None
            )
            password_hash_prev = (
                existing["password_hash_prev"] if existing is not None else None
            )
        elif p["password_hash"] is None:
            if p.get("password_salt") is not None or p.get("password_iterations") is not None:
                raise ValueError("unprotected notebook requires null password metadata")
            incoming_prev = p.get("password_hash_prev")
            if incoming_prev is not None and (
                not isinstance(incoming_prev, str) or not incoming_prev
            ):
                raise ValueError("password_hash_prev must be a non-empty string or null")
            held_hash = existing["password_hash"] if existing is not None else None
            held_prev = existing["password_hash_prev"] if existing is not None else None
            if existing is None:
                # A fresh/reset server has no generation to defend. Preserve
                # the durable tuple verbatim, including its clear tombstone.
                password_hash = None
                password_salt = None
                password_iterations = None
                password_hash_prev = incoming_prev
            elif held_hash is not None:
                if incoming_prev == held_hash:
                    password_hash = None
                    password_salt = None
                    password_iterations = None
                    password_hash_prev = held_hash
                else:
                    # A causally stale peer may still have a legitimate body
                    # edit. Land that edit without letting its verifier tuple
                    # weaken or replace the canonical server generation.
                    password_hash = held_hash
                    password_salt = existing["password_salt"]
                    password_iterations = existing["password_iterations"]
                    password_hash_prev = held_prev
            elif held_prev is not None:
                password_hash = None
                password_salt = None
                password_iterations = None
                password_hash_prev = held_prev
            else:
                password_hash = None
                password_salt = None
                password_iterations = None
                password_hash_prev = None
        else:
            password_hash = p["password_hash"]
            if not isinstance(password_hash, str) or not password_hash:
                raise ValueError("password_hash must be a non-empty string")
            password_salt = p.get("password_salt")
            password_iterations = p.get("password_iterations")
            if not isinstance(password_salt, str) or not password_salt:
                raise ValueError("protected notebook requires password_salt")
            if (
                type(password_iterations) is not int
                or not 100_000 <= password_iterations <= 1_000_000
            ):
                raise ValueError(
                    "protected notebook requires sane password_iterations"
                )
            incoming_prev = p.get("password_hash_prev")
            if incoming_prev is not None and (
                not isinstance(incoming_prev, str) or not incoming_prev
            ):
                raise ValueError("password_hash_prev must be a non-empty string or null")
            held_hash = existing["password_hash"] if existing is not None else None
            held_prev = existing["password_hash_prev"] if existing is not None else None
            if existing is None:
                # A fresh/reset server has no generation to compare against.
                # The incoming durable tuple is the only canonical state.
                password_hash_prev = incoming_prev
            elif password_hash == held_hash:
                # An ordinary body edit re-pushes the current hash. Keep the
                # entire canonical tuple: changing its salt/iterations while
                # retaining the hash would make the password unverifiable.
                password_salt = existing["password_salt"]
                password_iterations = existing["password_iterations"]
                password_hash_prev = held_prev
            elif held_hash is not None:
                if incoming_prev == held_hash:
                    password_hash_prev = held_hash
                else:
                    password_hash = held_hash
                    password_salt = existing["password_salt"]
                    password_iterations = existing["password_iterations"]
                    password_hash_prev = held_prev
            elif held_prev is not None:
                if incoming_prev == held_prev and password_hash != held_prev:
                    password_hash_prev = held_prev
                else:
                    password_hash = None
                    password_salt = None
                    password_iterations = None
                    password_hash_prev = held_prev
            else:
                if incoming_prev is None:
                    password_hash_prev = None
                else:
                    password_hash = None
                    password_salt = None
                    password_iterations = None
                    password_hash_prev = None
        conn.execute(
            """
            INSERT INTO notebooks
                (id, title, doc, ink, created_at, updated_at, deleted_at,
                 origin_device_id, folder_id, password_hash, password_salt,
                 password_iterations, password_hash_prev)
            VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                doc = excluded.doc,
                ink = excluded.ink,
                updated_at = excluded.updated_at,
                deleted_at = NULL,
                folder_id = excluded.folder_id,
                password_hash = excluded.password_hash,
                password_salt = excluded.password_salt,
                password_iterations = excluded.password_iterations,
                password_hash_prev = excluded.password_hash_prev
            """,
            (
                change.entity_id,
                p.get("title", "Untitled"),
                encoded,
                ink,
                int(p.get("created_at", now)),
                now,
                change.device_id,
                folder_id,
                password_hash,
                password_salt,
                password_iterations,
                password_hash_prev,
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
    reindex_ids: list[str] = []

    for change in body.changes:
        try:
            publish_payload = change.payload
            if change.entity_type == "ink_index":
                # The index is server-generated. Accepting a client's rows
                # would let a stale device overwrite fresher OCR output.
                raise ValueError("ink_index is server-generated; push rejected")
            if change.entity_type == "ask_message":
                raise ValueError("ask_message is server-generated; push rejected")
            if change.entity_type == "dump":
                _apply_dump(db, change, now)
                # Republish what the server now HOLDS, not what the device
                # sent. A device that never had the audio omits audio_kept,
                # and echoing that omission tells every other device the
                # recording is undownloadable while the file sits on disk.
                # Summary fields get the same treatment: server-held values
                # replace whatever the client sent (or omitted), so a title
                # edit can never broadcast a summary-less or forged payload.
                if change.op != "delete" and change.payload is not None:
                    stored = db.execute(
                        "SELECT audio_kept, summary, summary_model, "
                        "summarized_at, summary_template, speaker_names, language, translated, "
                        "summary_status, summary_error, summary_queue_position, transcript_timings, "
                        "timings_version, folder_id, auto_filed_at, "
                        "auto_file_prev_folder_id "
                        "FROM dumps WHERE id = ?",
                        (change.entity_id,),
                    ).fetchone()
                    if stored is not None:
                        publish_payload = dict(change.payload)
                        publish_payload["audio_kept"] = bool(stored["audio_kept"])
                        publish_payload["summary"] = stored["summary"]
                        publish_payload["summary_model"] = stored["summary_model"]
                        publish_payload["summarized_at"] = stored["summarized_at"]
                        publish_payload["summary_template"] = stored[
                            "summary_template"
                        ]
                        publish_payload["speaker_names"] = stored["speaker_names"]
                        publish_payload["language"] = stored["language"]
                        publish_payload["translated"] = bool(stored["translated"])
                        publish_payload["summary_status"] = stored["summary_status"]
                        publish_payload["summary_error"] = stored["summary_error"]
                        publish_payload["summary_queue_position"] = stored[
                            "summary_queue_position"
                        ]
                        publish_payload["transcript_timings"] = stored[
                            "transcript_timings"
                        ]
                        publish_payload["timings_version"] = stored["timings_version"]
                        # Filing as APPLIED (absent-key pushes keep the
                        # stored filing; echoing the omission would unfile
                        # the row on every other device), plus the
                        # server-authored auto-file markers.
                        publish_payload["folder_id"] = stored["folder_id"]
                        publish_payload["auto_filed_at"] = stored["auto_filed_at"]
                        publish_payload["auto_file_prev_folder_id"] = stored[
                            "auto_file_prev_folder_id"
                        ]
            elif change.entity_type == "notebook":
                _apply_document(db, "notebooks", change, now)
                if change.op != "delete" and change.payload is not None:
                    stored = db.execute(
                        "SELECT password_hash, password_salt, password_iterations, "
                        "password_hash_prev FROM notebooks WHERE id = ?",
                        (change.entity_id,),
                    ).fetchone()
                    if stored is not None:
                        publish_payload = dict(change.payload)
                        publish_payload["password_hash"] = stored["password_hash"]
                        publish_payload["password_salt"] = stored["password_salt"]
                        publish_payload["password_iterations"] = stored[
                            "password_iterations"
                        ]
                        publish_payload["password_hash_prev"] = stored[
                            "password_hash_prev"
                        ]
                # The OCR worker re-derives this notebook's index (a delete
                # purges it) — queued after the whole batch commits.
                reindex_ids.append(change.entity_id)
            elif change.entity_type == "folder":
                _apply_folder(db, change, now)
                # v1.30: folders.google_tasklist_id is server-only (spec
                # 2026-09-28 Data model). The upsert's column list never
                # writes it, and the published payload must never carry it
                # — even if a device echoes one back.
                if change.op != "delete" and change.payload is not None:
                    publish_payload = {
                        k: v for k, v in change.payload.items()
                        if k not in FOLDER_SERVER_ONLY_FIELDS
                    }
            elif change.entity_type == "todo":
                changed, publish_payload = _apply_todo(db, change, now)
                if not changed:
                    results.append(
                        SyncPushResult(
                            entity_id=change.entity_id,
                            entity_type=change.entity_type,
                            seq=0,
                            status="applied",
                        )
                    )
                    continue
            elif change.entity_type == "calendar_event":
                changed, publish_payload = _apply_calendar_event(db, change, now)
                if not changed:
                    results.append(
                        SyncPushResult(
                            entity_id=change.entity_id,
                            entity_type=change.entity_type,
                            seq=0,
                            status="applied",
                        )
                    )
                    continue
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
            canonical_payload = None
            if change.entity_type == "notebook":
                try:
                    canonical = db.execute(
                        "SELECT password_hash, password_salt, password_iterations, "
                        "password_hash_prev FROM notebooks WHERE id = ?",
                        (change.entity_id,),
                    ).fetchone()
                    if canonical is not None:
                        canonical_payload = {
                            "password_hash": canonical["password_hash"],
                            "password_salt": canonical["password_salt"],
                            "password_iterations": canonical["password_iterations"],
                            "password_hash_prev": canonical["password_hash_prev"],
                        }
                except sqlite3.Error:
                    # Preserve the original per-entity rejection if even the
                    # readback failed; the client will keep the row dirty.
                    pass
            results.append(
                SyncPushResult(
                    entity_id=change.entity_id,
                    entity_type=change.entity_type,
                    seq=0,
                    status="rejected",
                    reason=str(exc),
                    canonical_payload=canonical_payload,
                )
            )

    head = head_seq(db)
    db.execute(
        "UPDATE devices SET last_seen_seq = ?, last_seen_at = ? WHERE device_id = ?",
        (head, now, body.device_id),
    )
    # Commit BEFORE waking the worker: it reads on its own connection, and an
    # enqueue racing an uncommitted transaction would index the previous ink
    # with no later trigger to fix it.
    db.commit()
    for notebook_id in reindex_ids:
        ocr_worker.enqueue(notebook_id)
    log.info(
        "sync.push",
        device_id=body.device_id,
        applied=sum(1 for r in results if r.status == "applied"),
        rejected=sum(1 for r in results if r.status == "rejected"),
    )
    return SyncPushResponse(results=results, head_seq=head)
