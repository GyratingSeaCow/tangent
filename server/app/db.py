# SPDX-License-Identifier: AGPL-3.0-or-later
"""SQLite connection layer + schema bootstrap."""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Generator
from pathlib import Path

from app.logging_config import get_logger

log = get_logger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS auth (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    token_hash TEXT NOT NULL,
    display_name TEXT,
    created_at INTEGER NOT NULL,
    setup_completed_at INTEGER
);

CREATE TABLE IF NOT EXISTS dumps (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('brain_dump', 'meeting', 'text_note')),
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    meeting_notes TEXT,
    -- AI summary (server-generated, nullable): the markdown summary itself,
    -- the exact GGUF stem that wrote it, and when. Sync rule: these flow
    -- server->client only; a client push never sets or clears them.
    summary TEXT,
    summary_model TEXT,
    summarized_at INTEGER,
    summary_template TEXT,
    speaker_names TEXT,
    language TEXT,
    translated INTEGER NOT NULL DEFAULT 0,
    summary_status TEXT CHECK (summary_status IN ('queued', 'running', 'failed')),
    summary_error TEXT,
    summary_queue_position INTEGER,
    transcript_timings TEXT,
    timings_version INTEGER,
    audio_kept INTEGER NOT NULL DEFAULT 0,
    -- v1.38: the SHARED folder this capture is filed under (same `folders`
    -- table notebooks and todos point at). NULL means unfiled. Device-writable
    -- via sync; the auto-file trigger writes it server-side too.
    folder_id TEXT,
    -- v1.38 auto-file markers (server-authored): when the server filed this
    -- capture and what filing it replaced (for the client's Undo). Cleared
    -- whenever a device pushes its own filing for the row.
    auto_filed_at INTEGER,
    auto_file_prev_folder_id TEXT,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_dumps_client_id ON dumps(client_id);
CREATE INDEX IF NOT EXISTS idx_dumps_created_at ON dumps(created_at DESC);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL,
    dump_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    model TEXT NOT NULL,
    started_at INTEGER,
    completed_at INTEGER,
    result_transcript TEXT,
    result_segments TEXT,
    error TEXT,
    FOREIGN KEY (dump_id) REFERENCES dumps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_dump_id ON jobs(dump_id);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dump_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (dump_id) REFERENCES dumps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_events_dump_id ON events(dump_id);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at DESC);

-- Multi-device sync ------------------------------------------------------
--
-- The server owns one monotonically increasing sequence. Every mutation it
-- accepts is stamped with the next value, and a client asks "what changed
-- after N?". This is a CHECKPOINT, not a clock: it is assigned by a single
-- authority, so a device whose wall-clock is ten minutes fast is irrelevant.
--
-- Last-write-wins on updated_at was rejected on data-loss grounds — at
-- whole-notebook granularity it silently destroys a page of handwriting when
-- another device saves a title edit a second later.

CREATE TABLE IF NOT EXISTS change_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL
        CHECK (entity_type IN ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo', 'todo_column', 'calendar_event', 'ask_message', 'tag', 'tag_assignment')),
    entity_id TEXT NOT NULL,
    op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
    -- Who authored it, so a client can skip the echo of its own push.
    device_id TEXT NOT NULL,
    -- Full entity for an upsert; NULL for a delete.
    payload TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
CREATE INDEX IF NOT EXISTS idx_change_log_entity
    ON change_log(entity_type, entity_id);

CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_seen_seq INTEGER NOT NULL DEFAULT 0,
    last_seen_at INTEGER
);

-- Pairing: how a second device earns a token by reading the 6-digit code
-- off the server's output. Rows are 120-second ephemera; the raw code is
-- NEVER stored (only its hash), and a restart voids pending pairings.
CREATE TABLE IF NOT EXISTS pairings (
    pair_id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL,
    device_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    consumed_at INTEGER
);

-- Per-device bearer tokens minted by pairing. The original single-token
-- auth row stays untouched as the primary credential; these ADD devices
-- and can be revoked one at a time without re-pairing everything else.
CREATE TABLE IF NOT EXISTS device_tokens (
    device_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL,
    display_name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
);

-- Notebooks and text notes: the things the user actually asked to sync.
-- The document body travels as opaque JSON so the server never has to
-- understand ink, and a client-side schema change does not require a server
-- deploy. Merge happens on the client, per the design doc.

CREATE TABLE IF NOT EXISTS notebooks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    -- {"blocks": [...]} — the text-block body. Strokes do NOT live here:
    -- the client pushes 'doc' and 'ink' as SEPARATE payload fields.
    doc TEXT NOT NULL,
    -- {"strokes": [...]} — the handwriting, stored server-side so the OCR
    -- worker can read it without spelunking change_log payloads. NULL when
    -- the notebook has never carried ink.
    ink TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    origin_device_id TEXT,
    folder_id TEXT,
    -- Salted PBKDF2-HMAC-SHA256 verifier metadata. Never plaintext.
    password_hash TEXT,
    password_salt TEXT,
    password_iterations INTEGER,
    -- Causal proof for verifier transitions and cleared-generation tombstone.
    password_hash_prev TEXT
);

CREATE INDEX IF NOT EXISTS idx_notebooks_updated_at
    ON notebooks(updated_at DESC);

CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    origin_device_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);

-- Handwriting search index: one row per recognized WORD, grouped by the
-- line that produced it. line_id is the sha1 of the line's sorted member
-- stroke ids (Task 1) — a stable invalidation key: any stroke edit changes
-- the set, so unchanged lines keep their rows untouched.
CREATE TABLE IF NOT EXISTS ink_index (
    id TEXT PRIMARY KEY,
    notebook_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    word_text TEXT NOT NULL,
    word_text_lower TEXT NOT NULL,
    bbox_json TEXT NOT NULL,
    stroke_ids_json TEXT NOT NULL,
    model TEXT NOT NULL,
    indexed_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ink_index_notebook ON ink_index(notebook_id);
CREATE INDEX IF NOT EXISTS idx_ink_index_word_lower
    ON ink_index(word_text_lower);


-- Folders sync by ID only: same-named folders created independently on two
-- devices stay separate (user decision). One folder can hold notebooks and
-- recordings alike; the server only relays, filing semantics live client-side.
CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    origin_device_id TEXT,
    -- v1.30: the Google task list mirroring this folder. Server-only —
    -- never in a sync payload, preserved across device upserts.
    google_tasklist_id TEXT
);

CREATE TABLE IF NOT EXISTS todos (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    done_at TEXT,
    due_date TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    source_ref TEXT,
    folder_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    -- Google bookkeeping is server-only. It is deliberately absent from
    -- device sync payloads and from _apply_todo's upsert column list.
    google_task_id TEXT,
    google_updated TEXT,
    -- v1.30: the list the task currently lives in ON GOOGLE (source list
    -- for tasks.move). Server-only, same projection rule.
    google_tasklist_id TEXT,
    column_id TEXT,
    board_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS todo_columns (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_todos_updated_at ON todos(updated_at DESC);

CREATE TABLE IF NOT EXISTS calendar_events (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    start TEXT NOT NULL,
    end_ TEXT NOT NULL,
    all_day INTEGER NOT NULL DEFAULT 1,
    time_zone TEXT NOT NULL,
    needs_date INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'voice',
    source_ref TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    -- Server-authored Google bookkeeping; projected out of device pushes.
    google_event_id TEXT,
    google_html_link TEXT,
    google_updated TEXT
);

CREATE INDEX IF NOT EXISTS idx_calendar_events_updated_at
    ON calendar_events(updated_at DESC);

CREATE TABLE IF NOT EXISTS ask_messages (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    text TEXT NOT NULL,
    sources_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ask_messages_created_at
    ON ask_messages(created_at, id);

-- One household-wide Google Tasks connection. Credentials and tokens never
-- enter the device sync feed; authenticated APIs expose only status metadata.
CREATE TABLE IF NOT EXISTS google_tasks_link (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    client_id TEXT,
    client_secret TEXT,
    refresh_token TEXT,
    access_token TEXT,
    access_expires_at INTEGER,
    google_email TEXT,
    tasklist_id TEXT,
    last_pull_updated_min TEXT,
    status TEXT NOT NULL DEFAULT 'disconnected'
        CHECK (status IN
               ('disconnected', 'pending', 'connected', 'reauth_required', 'error')),
    last_error TEXT,
    last_sync_at TEXT,
    last_pushed INTEGER NOT NULL DEFAULT 0,
    last_pulled INTEGER NOT NULL DEFAULT 0,
    last_moved INTEGER NOT NULL DEFAULT 0,
    oauth_state TEXT,
    oauth_state_expires_at INTEGER,
    granted_scope TEXT,
    calendar_sync_token TEXT,
    last_cal_pushed INTEGER NOT NULL DEFAULT 0,
    last_cal_pulled INTEGER NOT NULL DEFAULT 0,
    last_cal_error TEXT
);

-- v1.30 folders <-> Google lists: one pull cursor (updatedMin) per managed
-- Google task list — the unfiled "Tangent" list plus one list per live
-- folder. The pre-v1.30 single cursor on google_tasks_link migrates in as
-- the unfiled list's row (see _migrate_google_lists).
CREATE TABLE IF NOT EXISTS google_list_cursor (
    tasklist_id TEXT PRIMARY KEY,
    updated_min TEXT
);

-- Server-side persisted settings (key/value). First user: the AI-summaries
-- toggle — it gates a SERVER worker, so it must live where the worker can
-- read it, not in a client's secure storage.
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Shared custom tags: one vocabulary for notebooks AND recordings. Tags
-- sync by id (same-named tags made offline on two devices stay separate,
-- the folder precedent). Deletes tombstone, never remove.
CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    origin_device_id TEXT
);

-- Polymorphic assignment: target_type says which table target_id names.
-- Deliberately no foreign key to either target (a trashed notebook keeps
-- its tags for a restore). The id is derived from the triple
-- (see app.api.sync.tag_assignment_id), so the same tag on the same item is
-- one row fleet-wide; the UNIQUE constraint backs that up.
CREATE TABLE IF NOT EXISTS tag_assignments (
    id TEXT PRIMARY KEY,
    tag_id TEXT NOT NULL,
    target_type TEXT NOT NULL CHECK (target_type IN ('notebook', 'dump')),
    target_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    origin_device_id TEXT,
    UNIQUE (tag_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_tag_assignments_target
    ON tag_assignments(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_tag_assignments_tag
    ON tag_assignments(tag_id);

-- v1.41 Morning Brief: one cached AI brief per server-local date
-- (YYYY-MM-DD). Server-only; never on the sync feed — clients GET it.
CREATE TABLE IF NOT EXISTS morning_briefs (
    date TEXT PRIMARY KEY,
    brief_md TEXT NOT NULL,
    model TEXT NOT NULL,
    generated_at INTEGER NOT NULL
);
"""


def _db_path(data_dir: str) -> Path:
    return Path(data_dir) / "tangent.db"


def _migrate_google_link_scope(conn: sqlite3.Connection) -> None:
    """Add Calendar OAuth, cursor, and status fields to existing links."""
    columns = {
        row[1] for row in conn.execute("PRAGMA table_info(google_tasks_link)")
    }
    additions = {
        "granted_scope": "TEXT",
        "calendar_sync_token": "TEXT",
        "last_cal_pushed": "INTEGER NOT NULL DEFAULT 0",
        "last_cal_pulled": "INTEGER NOT NULL DEFAULT 0",
        "last_cal_error": "TEXT",
    }
    for name, ddl in additions.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE google_tasks_link ADD COLUMN {name} {ddl}")


def _migrate_jobs_request_id(conn: sqlite3.Connection) -> None:
    columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
    if "request_id" not in columns:
        conn.execute("ALTER TABLE jobs ADD COLUMN request_id TEXT")
    conn.execute(
        "UPDATE jobs SET request_id = 'legacy:' || id "
        "WHERE request_id IS NULL OR request_id = ''"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_request_id "
        "ON jobs(request_id)"
    )


def _migrate_jobs_result_segments(conn: sqlite3.Connection) -> None:
    """Add the nullable result_segments column to pre-segments databases.

    Stores the JSON-encoded segment list. NULL means "no segments recorded"
    (queued, failed, or a job completed before this column existed) — which is
    deliberately distinct from '[]' meaning "transcribed, no speech found".
    """
    columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
    if "result_segments" not in columns:
        conn.execute("ALTER TABLE jobs ADD COLUMN result_segments TEXT")


def _reconcile_audio_kept(conn: sqlite3.Connection, data_dir: str) -> None:
    """Make ``audio_kept`` reflect what is actually in the audio directory.

    The upload route historically never set the flag, so every row reads 0
    even when the file is on disk. Runs before the change-feed backfill so
    the published payloads carry the truth. Only promotes 0 -> 1; it never
    clears the flag, so a temporarily unmounted directory cannot erase the
    server's knowledge.
    """
    audio_dir = Path(data_dir) / "audio"
    if not audio_dir.is_dir():
        return
    on_disk = {p.stem for p in audio_dir.iterdir() if p.is_file()}
    if not on_disk:
        return
    rows = conn.execute(
        "SELECT id FROM dumps WHERE audio_kept = 0"
    ).fetchall()
    for (dump_id,) in rows:
        if dump_id in on_disk:
            conn.execute(
                "UPDATE dumps SET audio_kept = 1 WHERE id = ?", (dump_id,)
            )


def _backfill_dump_change_feed(conn: sqlite3.Connection) -> None:
    """Publish an upsert for every live dump the change feed has never seen.

    Recordings made before dump sync existed have rows in ``dumps`` but no
    entry in ``change_log``, so a peer pulling from seq 0 would never learn
    they exist. Idempotent: only dumps with no feed entry are published, so
    reruns add nothing. Attributed to 'server' — pull excludes only the
    caller's own device_id, so every real device receives these.
    """
    import json as _json
    import time as _time

    prior = conn.row_factory
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            SELECT d.* FROM dumps d
            WHERE d.deleted_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM change_log c
                WHERE c.entity_type = 'dump' AND c.entity_id = d.id
              )
            """
        ).fetchall()
        now = int(_time.time())
        for row in rows:
            payload = {
                "client_id": row["client_id"],
                "mode": row["mode"],
                "title": row["title"],
                "transcript": row["transcript"],
                "meeting_notes": row["meeting_notes"],
                "summary": row["summary"],
                "summary_model": row["summary_model"],
                "summarized_at": row["summarized_at"],
                "summary_template": row["summary_template"],
                "speaker_names": row["speaker_names"],
                "language": row["language"],
                "translated": bool(row["translated"]),
                "summary_status": row["summary_status"],
                "summary_error": row["summary_error"],
                "summary_queue_position": row["summary_queue_position"],
                "transcript_timings": row["transcript_timings"],
                "timings_version": row["timings_version"],
                "duration_seconds": row["duration_seconds"],
                "audio_kept": bool(row["audio_kept"]),
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }
            conn.execute(
                "INSERT INTO change_log "
                "(entity_type, entity_id, op, device_id, payload, created_at) "
                "VALUES ('dump', ?, 'upsert', 'server', ?, ?)",
                (row["id"], _json.dumps(payload), now),
            )
    finally:
        conn.row_factory = prior


def _migrate_dumps_meeting_notes(conn: sqlite3.Connection) -> None:
    """Dump sync carries meeting notes; older databases lack the column.

    Same defensive shape as the other migrations: ask the table, never the
    version — adding a column twice is an OperationalError that would stop
    the server from booting.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(dumps)")}
    if "meeting_notes" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN meeting_notes TEXT")


def _migrate_dumps_summary(conn: sqlite3.Connection) -> None:
    """AI-summaries columns: additive, nullable, per the existing pattern.

    NULL means "never summarized" — deliberately distinct from '' (which a
    fully-empty postprocessed output could produce but the worker never
    stores; it leaves NULL and logs instead).
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(dumps)")}
    if "summary" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN summary TEXT")
    if "summary_model" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN summary_model TEXT")
    if "summarized_at" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN summarized_at INTEGER")


def _migrate_dumps_summary_template(conn: sqlite3.Connection) -> list[str]:
    """Add the nullable template wire field and republish legacy live dumps.

    Older change-log payloads cannot distinguish an absent field from an
    explicit null. Publishing once when the column is first added gives every
    client the null sentinel; asking ``PRAGMA table_info`` keeps this
    idempotent without a separate schema-version ledger.
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    if "summary_template" in cols:
        return []
    conn.execute("ALTER TABLE dumps ADD COLUMN summary_template TEXT")
    return [
        row[0]
        for row in conn.execute("SELECT id FROM dumps WHERE deleted_at IS NULL")
    ]


def _migrate_dumps_speaker_names(conn: sqlite3.Connection) -> list[str]:
    """Add the nullable speaker-name map and republish legacy live dumps."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    if "speaker_names" in cols:
        return []
    conn.execute("ALTER TABLE dumps ADD COLUMN speaker_names TEXT")
    return [
        row[0]
        for row in conn.execute("SELECT id FROM dumps WHERE deleted_at IS NULL")
    ]


def _migrate_dumps_speaker_embeddings(conn: sqlite3.Connection) -> None:
    """Server-private per-speaker centroids from diarization (v1.36.0)."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    if "speaker_embeddings" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN speaker_embeddings TEXT")


def _migrate_voice_book(conn: sqlite3.Connection) -> None:
    """Create the voice book and migrate legacy unit centroids to sums.

    Multiplying a legacy centroid by its sample count is the only bounded
    approximation available.  Later teach/unteach operations are exact.
    """
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_book (
            name TEXT PRIMARY KEY,
            embedding TEXT NOT NULL,
            samples INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_book_samples (
            dump_id TEXT NOT NULL,
            label TEXT NOT NULL,
            name TEXT NOT NULL,
            embedding TEXT NOT NULL,
            PRIMARY KEY (dump_id, label)
        )
        """
    )
    migrated = conn.execute(
        "SELECT value FROM app_settings WHERE key = 'voice_book_sum_format'"
    ).fetchone()
    if migrated is None:
        rows = conn.execute("SELECT name, embedding, samples FROM voice_book").fetchall()
        for name, raw, samples in rows:
            try:
                if int(samples) < 1:
                    raise ValueError("samples must be positive")
                centroid = json.loads(raw)
                summed = [float(value) * int(samples) for value in centroid]
            except (TypeError, ValueError, json.JSONDecodeError) as exc:
                log.warning(
                    "voice_book.sum_migration_skipped", name=name, error=str(exc)
                )
                continue  # preserve corrupt rows for normal validation to report
            conn.execute(
                "UPDATE voice_book SET embedding = ? WHERE name = ?",
                (json.dumps(summed), name),
            )
        conn.execute(
            "INSERT INTO app_settings (key, value) VALUES ('voice_book_sum_format', '1')"
        )


def _migrate_dumps_language(conn: sqlite3.Connection) -> list[str]:
    """Add server-authored translation metadata and republish once."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    added = False
    if "language" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN language TEXT")
        added = True
    if "translated" not in cols:
        conn.execute(
            "ALTER TABLE dumps ADD COLUMN translated INTEGER NOT NULL DEFAULT 0"
        )
        added = True
    if not added:
        return []
    return [
        row[0]
        for row in conn.execute("SELECT id FROM dumps WHERE deleted_at IS NULL")
    ]


def _migrate_dumps_summary_status(conn: sqlite3.Connection) -> list[str]:
    """Add server-authored summary state and republish once."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    added = False
    for name, declaration in (
        ("summary_status", "TEXT"),
        ("summary_error", "TEXT"),
        ("summary_queue_position", "INTEGER"),
    ):
        if name not in cols:
            conn.execute(f"ALTER TABLE dumps ADD COLUMN {name} {declaration}")
            added = True
    if not added:
        return []
    return [
        row[0]
        for row in conn.execute("SELECT id FROM dumps WHERE deleted_at IS NULL")
    ]


def _migrate_dumps_transcript_timings(conn: sqlite3.Connection) -> list[str]:
    """Add dump-level transcript timings and backfill legacy job segments."""
    import json as _json
    import time as _time

    cols = {r[1] for r in conn.execute("PRAGMA table_info(dumps)")}
    added_columns = False
    if "transcript_timings" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN transcript_timings TEXT")
        added_columns = True
    if "timings_version" not in cols:
        conn.execute("ALTER TABLE dumps ADD COLUMN timings_version INTEGER")
        added_columns = True
    if not added_columns:
        return []

    rows = conn.execute(
        "SELECT id FROM dumps WHERE transcript_timings IS NULL"
    ).fetchall()
    backfilled_ids: list[str] = []
    for (dump_id,) in rows:
        job = conn.execute(
            """
            SELECT result_segments FROM jobs
            WHERE dump_id = ? AND status = 'completed'
              AND result_segments IS NOT NULL AND result_segments != ''
            ORDER BY completed_at DESC, rowid DESC LIMIT 1
            """,
            (dump_id,),
        ).fetchone()
        if job is None:
            continue
        try:
            segments = _json.loads(job[0])
        except (TypeError, ValueError):
            continue
        if not isinstance(segments, list) or not segments:
            continue
        if not all(isinstance(segment, dict) for segment in segments):
            continue
        backfilled = {
            "segments": [
                {**segment, "words": segment.get("words", [])}
                for segment in segments
            ],
            "peaks": [],
        }
        conn.execute(
            "UPDATE dumps SET transcript_timings = ?, timings_version = 1, "
            "updated_at = ? WHERE id = ? AND transcript_timings IS NULL",
            (_json.dumps(backfilled), int(_time.time()), dump_id),
        )
        backfilled_ids.append(dump_id)
    return backfilled_ids


def _migrate_dumps_mode_check(conn: sqlite3.Connection) -> None:
    """Rebuild dumps if its mode CHECK predates text_note. Idempotent."""
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'dumps'"
    ).fetchone()
    if row is None or "text_note" in row[0]:
        return
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE dumps_new (
            id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            mode TEXT NOT NULL
                CHECK (mode IN ('brain_dump', 'meeting', 'text_note')),
            duration_seconds INTEGER NOT NULL,
            title TEXT NOT NULL,
            transcript TEXT,
            audio_kept INTEGER NOT NULL DEFAULT 0,
            deleted_at INTEGER
        );
        INSERT INTO dumps_new
            SELECT id, client_id, created_at, updated_at, mode,
                   duration_seconds, title, transcript, audio_kept, deleted_at
            FROM dumps;
        DROP TABLE dumps;
        ALTER TABLE dumps_new RENAME TO dumps;
        CREATE INDEX IF NOT EXISTS idx_dumps_client_id ON dumps(client_id);
        CREATE INDEX IF NOT EXISTS idx_dumps_created_at
            ON dumps(created_at DESC);
        PRAGMA foreign_keys = ON;
        """
    )


def _migrate_dumps_folder_id(conn: sqlite3.Connection) -> None:
    """Add filing + auto-file markers to pre-auto-file dumps. NULL means
    unfiled / never auto-filed; nothing is republished (there is nothing to
    announce until a filing actually changes)."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    for name, declaration in (
        ("folder_id", "TEXT"),
        ("auto_filed_at", "INTEGER"),
        ("auto_file_prev_folder_id", "TEXT"),
    ):
        if name not in cols:
            conn.execute(f"ALTER TABLE dumps ADD COLUMN {name} {declaration}")


def _migrate_notebooks_folder_id(conn: sqlite3.Connection) -> None:
    """Add folder_id to pre-folder-sync notebooks. NULL means unfiled."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(notebooks)")}
    if "folder_id" not in columns:
        conn.execute("ALTER TABLE notebooks ADD COLUMN folder_id TEXT")


def _migrate_notebooks_password_metadata(conn: sqlite3.Connection) -> None:
    """Add nullable verifier metadata and transition proof/tombstone."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(notebooks)")}
    for name, declaration in (
        ("password_hash", "TEXT"),
        ("password_salt", "TEXT"),
        ("password_iterations", "INTEGER"),
        ("password_hash_prev", "TEXT"),
    ):
        if name not in columns:
            conn.execute(
                f"ALTER TABLE notebooks ADD COLUMN {name} {declaration}"
            )


def _migrate_todos_folder_id(conn: sqlite3.Connection) -> None:
    """Add folder_id to pre-folder-sync todos. NULL means unfiled."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(todos)")}
    if "folder_id" not in columns:
        conn.execute("ALTER TABLE todos ADD COLUMN folder_id TEXT")


def _migrate_todos_google_columns(conn: sqlite3.Connection) -> None:
    """Add opaque Google mapping metadata to pre-v1.25 todo tables."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(todos)")}
    if "google_task_id" not in columns:
        conn.execute("ALTER TABLE todos ADD COLUMN google_task_id TEXT")
    if "google_updated" not in columns:
        conn.execute("ALTER TABLE todos ADD COLUMN google_updated TEXT")


def _migrate_todo_kanban(conn: sqlite3.Connection) -> None:
    """Add synced Kanban placement to existing todos."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(todos)")}
    if "column_id" not in columns:
        conn.execute("ALTER TABLE todos ADD COLUMN column_id TEXT")
    if "board_order" not in columns:
        conn.execute("ALTER TABLE todos ADD COLUMN board_order INTEGER NOT NULL DEFAULT 0")


def _migrate_google_lists(conn: sqlite3.Connection) -> None:
    """v1.30 folders <-> Google lists (spec 2026-09-28, Data model).

    Guarded ALTERs for ``folders.google_tasklist_id`` and
    ``todos.google_tasklist_id`` (both server-only, projected out of the
    sync feed). Then seed ``google_list_cursor`` from the pre-v1.30 single
    ``last_pull_updated_min`` on the link row: that cursor belonged to the
    unfiled "Tangent" list, so it becomes that list's row (rule 5). Existing
    tasks were all pushed into the unfiled list, so their recorded list is
    back-filled to it — otherwise the first v1.30 push would ``move`` every
    mapped task from an unknown source list. Idempotent.
    """
    folder_columns = {row[1] for row in conn.execute("PRAGMA table_info(folders)")}
    if "google_tasklist_id" not in folder_columns:
        conn.execute("ALTER TABLE folders ADD COLUMN google_tasklist_id TEXT")
    todo_columns = {row[1] for row in conn.execute("PRAGMA table_info(todos)")}
    if "google_tasklist_id" not in todo_columns:
        conn.execute("ALTER TABLE todos ADD COLUMN google_tasklist_id TEXT")
    link_columns = {row[1] for row in conn.execute("PRAGMA table_info(google_tasks_link)")}
    if "last_moved" not in link_columns:
        conn.execute(
            "ALTER TABLE google_tasks_link ADD COLUMN last_moved INTEGER NOT NULL DEFAULT 0"
        )
    link = conn.execute(
        "SELECT tasklist_id, last_pull_updated_min FROM google_tasks_link WHERE id = 1"
    ).fetchone()
    if link is None or not link[0]:
        return
    unfiled_list = str(link[0])
    conn.execute(
        "INSERT OR IGNORE INTO google_list_cursor (tasklist_id, updated_min) VALUES (?, ?)",
        (unfiled_list, link[1]),
    )
    conn.execute(
        "UPDATE todos SET google_tasklist_id = ? "
        "WHERE google_task_id IS NOT NULL AND google_tasklist_id IS NULL",
        (unfiled_list,),
    )


def _migrate_change_log_folder_entity(conn: sqlite3.Connection) -> None:
    """Rebuild change_log so its CHECK admits entity_type 'folder'.

    SQLite cannot alter a CHECK in place. The rebuild must preserve seq
    values exactly — every device's checkpoint points into this sequence,
    and renumbering would make them all silently skip or re-apply changes.
    """
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or "'folder'" in (ddl[0] or ""):
        return
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL
                CHECK (entity_type IN ('dump', 'notebook', 'note', 'folder')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    # AUTOINCREMENT continuity: sqlite_sequence must not fall behind the
    # copied rows, or the next insert would collide with an existing seq.
    conn.execute(
        "INSERT OR REPLACE INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', COALESCE(MAX(seq), 0) FROM change_log"
    )


def _migrate_change_log_ink_index_entity(conn: sqlite3.Connection) -> None:
    """Rebuild change_log so its CHECK admits entity_type 'ink_index'.

    Same shape and same seq-preservation obligation as the folder-entity
    rebuild above: every device's checkpoint points into this sequence.
    """
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or "'ink_index'" in (ddl[0] or ""):
        return
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL
                CHECK (entity_type IN
                       ('dump', 'notebook', 'note', 'folder', 'ink_index')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    conn.execute(
        "INSERT OR REPLACE INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', COALESCE(MAX(seq), 0) FROM change_log"
    )


def _migrate_change_log_todo_entity(conn: sqlite3.Connection) -> None:
    """Rebuild change_log to admit todo without renumbering checkpoints."""
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or "'todo'" in (ddl[0] or ""):
        return
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL
                CHECK (entity_type IN
                       ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    conn.execute(
        "INSERT OR REPLACE INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', COALESCE(MAX(seq), 0) FROM change_log"
    )


def _migrate_change_log_calendar_event_entity(conn: sqlite3.Connection) -> None:
    """Rebuild change_log to admit calendar_event without renumbering checkpoints."""
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or "'calendar_event'" in (ddl[0] or ""):
        return
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL
                CHECK (entity_type IN
                       ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo',
                        'calendar_event')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    conn.execute(
        "INSERT OR REPLACE INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', COALESCE(MAX(seq), 0) FROM change_log"
    )


def _migrate_change_log_ask_message_entity(conn: sqlite3.Connection) -> None:
    """Rebuild change_log to admit Ask, Kanban, and shared-tag entities."""
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or all(
        value in (ddl[0] or "") for value in ("'ask_message'", "'todo_column'")
    ):
        return
    prior = conn.execute(
        "SELECT seq FROM sqlite_sequence WHERE name = 'change_log'"
    ).fetchone()
    prior_seq = int(prior[0]) if prior is not None else 0
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL CHECK (entity_type IN
                ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo',
                 'todo_column', 'calendar_event', 'ask_message', 'tag',
                 'tag_assignment')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    conn.execute("DELETE FROM sqlite_sequence WHERE name = 'change_log'")
    conn.execute(
        "INSERT INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', MAX(?, COALESCE(MAX(seq), 0)) FROM change_log",
        (prior_seq,),
    )


def _migrate_change_log_tag_entities(conn: sqlite3.Connection) -> None:
    """Rebuild change_log to admit shared tags and their assignments.

    Idempotent: a log whose CHECK already names 'tag_assignment' is left
    alone, and every existing row (and the AUTOINCREMENT high-water mark) is
    carried across, so no device's checkpoint is invalidated.
    """
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='change_log'"
    ).fetchone()
    if ddl is None or "'tag_assignment'" in (ddl[0] or ""):
        return
    # The true high-water mark, read BEFORE the old table (and its
    # sqlite_sequence row) is dropped. MAX(seq) alone would hand a deleted
    # tail seq out again, and a device already checkpointed past it would
    # silently skip that new change.
    prior = conn.execute(
        "SELECT seq FROM sqlite_sequence WHERE name = 'change_log'"
    ).fetchone()
    prior_seq = int(prior[0]) if prior is not None else 0
    conn.executescript(
        """
        PRAGMA foreign_keys = OFF;
        CREATE TABLE change_log_new (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL CHECK (entity_type IN
                ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo',
                 'todo_column', 'calendar_event', 'ask_message', 'tag',
                 'tag_assignment')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log_new
            (seq, entity_type, entity_id, op, device_id, payload, created_at)
            SELECT seq, entity_type, entity_id, op, device_id, payload,
                   created_at FROM change_log;
        DROP TABLE change_log;
        ALTER TABLE change_log_new RENAME TO change_log;
        CREATE INDEX IF NOT EXISTS idx_change_log_seq ON change_log(seq);
        CREATE INDEX IF NOT EXISTS idx_change_log_entity
            ON change_log(entity_type, entity_id);
        PRAGMA foreign_keys = ON;
        """
    )
    # sqlite_sequence has no unique key on name: replace, never duplicate.
    conn.execute("DELETE FROM sqlite_sequence WHERE name = 'change_log'")
    conn.execute(
        "INSERT INTO sqlite_sequence (name, seq) "
        "SELECT 'change_log', MAX(?, COALESCE(MAX(seq), 0)) FROM change_log",
        (prior_seq,),
    )


def _migrate_notebooks_ink(conn: sqlite3.Connection) -> None:
    """Add notebooks.ink and backfill it from the change feed.

    The client has ALWAYS pushed 'doc' and 'ink' as separate payload fields,
    but the push handler historically stored only 'doc' — so on a production
    server the strokes live solely inside change_log upsert payloads. The
    OCR worker needs them queryable per notebook.

    Backfill rule: the NEWEST payload CARRYING an 'ink' key wins. A later
    title-only upsert (older client, or a metadata edit) simply lacks the
    key — absence is not an eraser, same rule the push path applies.
    """
    import json as _json

    columns = {row[1] for row in conn.execute("PRAGMA table_info(notebooks)")}
    if "ink" not in columns:
        conn.execute("ALTER TABLE notebooks ADD COLUMN ink TEXT")

    empty = [
        row[0]
        for row in conn.execute("SELECT id FROM notebooks WHERE ink IS NULL")
    ]
    for nb_id in empty:
        payload_rows = conn.execute(
            "SELECT payload FROM change_log "
            "WHERE entity_type = 'notebook' AND entity_id = ? AND op = 'upsert' "
            "ORDER BY seq DESC",
            (nb_id,),
        ).fetchall()
        for (raw,) in payload_rows:
            if not raw:
                continue
            try:
                payload = _json.loads(raw)
            except ValueError:
                continue
            if isinstance(payload, dict) and "ink" in payload:
                ink_val = payload["ink"]
                if isinstance(ink_val, str):
                    # The client pushes ink as JSON TEXT inside the payload.
                    # Dumping it AGAIN would double-encode: json.loads on the
                    # column would yield a str, the OCR worker would see no
                    # dict, and every notebook would silently index nothing.
                    # Store the text as-is — but only if it actually parses;
                    # otherwise fall back to an older payload.
                    try:
                        _json.loads(ink_val)
                    except ValueError:
                        log.warning(
                            "db.notebook_ink_backfill_unparseable",
                            notebook_id=nb_id,
                        )
                        continue
                    encoded = ink_val
                else:
                    encoded = _json.dumps(ink_val)
                conn.execute(
                    "UPDATE notebooks SET ink = ? WHERE id = ?",
                    (encoded, nb_id),
                )
                break


def _normalize_notebooks_ink(conn: sqlite3.Connection) -> None:
    """Repair double-encoded notebooks.ink rows in place.

    The original Task 3 backfill json.dumps()'d payload ink that was ALREADY
    JSON text, so json.loads(ink) yielded a str — the OCR worker saw no dict,
    no strokes, and silently indexed nothing. Runs every boot: idempotent and
    cheap (a healthy row costs one json.loads; only wrapped rows are
    rewritten). Handles N layers of wrapping; a value that never resolves to
    a dict is left untouched and logged.
    """
    import json as _json

    rows = conn.execute(
        "SELECT id, ink FROM notebooks WHERE ink IS NOT NULL"
    ).fetchall()
    for nb_id, raw in rows:
        try:
            value = _json.loads(raw)
        except ValueError:
            log.warning("db.notebook_ink_unparseable", notebook_id=nb_id)
            continue
        if not isinstance(value, str):
            continue  # canonical single-encoded row — nothing to do
        # Peel wrapper layers. Terminates: each loads strictly shrinks the
        # string; the cap is belt-and-braces against pathological data.
        for _ in range(10):
            if not isinstance(value, str):
                break
            try:
                value = _json.loads(value)
            except ValueError:
                break
        if isinstance(value, dict):
            conn.execute(
                "UPDATE notebooks SET ink = ? WHERE id = ?",
                (_json.dumps(value), nb_id),
            )
        else:
            log.warning("db.notebook_ink_unparseable", notebook_id=nb_id)


def init_db(data_dir: str) -> None:
    """Create the SQLite DB and apply schema. Idempotent."""
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    path = _db_path(data_dir)
    is_new = not path.exists()

    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
        _migrate_google_link_scope(conn)
        _migrate_jobs_request_id(conn)
        _migrate_jobs_result_segments(conn)
        _migrate_dumps_mode_check(conn)
        _migrate_dumps_meeting_notes(conn)
        _migrate_dumps_summary(conn)
        template_backfills = _migrate_dumps_summary_template(conn)
        speaker_name_backfills = _migrate_dumps_speaker_names(conn)
        _migrate_dumps_speaker_embeddings(conn)
        _migrate_voice_book(conn)
        language_backfills = _migrate_dumps_language(conn)
        summary_status_backfills = _migrate_dumps_summary_status(conn)
        timing_backfills = _migrate_dumps_transcript_timings(conn)
        _migrate_dumps_folder_id(conn)
        _migrate_notebooks_folder_id(conn)
        _migrate_notebooks_password_metadata(conn)
        _migrate_todos_folder_id(conn)
        _migrate_todos_google_columns(conn)
        _migrate_todo_kanban(conn)
        _migrate_google_lists(conn)
        _migrate_change_log_folder_entity(conn)
        _migrate_change_log_ink_index_entity(conn)
        _migrate_change_log_todo_entity(conn)
        _migrate_change_log_calendar_event_entity(conn)
        _migrate_change_log_ask_message_entity(conn)
        _migrate_change_log_tag_entities(conn)
        _migrate_notebooks_ink(conn)
        _normalize_notebooks_ink(conn)
        _reconcile_audio_kept(conn, data_dir)
        dump_backfills = (
            set(template_backfills)
            | set(speaker_name_backfills)
            | set(language_backfills)
            | set(summary_status_backfills)
            | set(timing_backfills)
        )
        if dump_backfills:
            from app.api.dumps import _publish_dump_change

            prior_factory = conn.row_factory
            conn.row_factory = sqlite3.Row
            try:
                for dump_id in sorted(dump_backfills):
                    _publish_dump_change(conn, dump_id, None)
            finally:
                conn.row_factory = prior_factory
        _backfill_dump_change_feed(conn)
        conn.commit()
    finally:
        conn.close()

    if is_new:
        log.info("database.initialized", path=str(path))
    else:
        log.debug("database.schema_applied", path=str(path))


def get_db() -> Generator[sqlite3.Connection, None, None]:
    """FastAPI dependency: yield a SQLite connection with Row factory.

    Commits on successful return, rolls back on exception.
    """
    from app.config import get_settings

    settings = get_settings()
    path = _db_path(settings.data_dir)

    # Ensure schema exists (covers the case where tests or first-launch
    # haven't called init_db explicitly)
    if not path.exists():
        init_db(settings.data_dir)

    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 30000")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
