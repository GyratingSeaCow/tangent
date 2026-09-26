# SPDX-License-Identifier: AGPL-3.0-or-later
"""SQLite connection layer + schema bootstrap."""

from __future__ import annotations

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
    transcript_timings TEXT,
    timings_version INTEGER,
    audio_kept INTEGER NOT NULL DEFAULT 0,
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
        CHECK (entity_type IN ('dump', 'notebook', 'note', 'folder', 'ink_index')),
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
    folder_id TEXT
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
    origin_device_id TEXT
);

-- Server-side persisted settings (key/value). First user: the AI-summaries
-- toggle — it gates a SERVER worker, so it must live where the worker can
-- read it, not in a client's secure storage.
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def _db_path(data_dir: str) -> Path:
    return Path(data_dir) / "tangent.db"


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
        backfilled = [{**segment, "words": segment.get("words", [])} for segment in segments]
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


def _migrate_notebooks_folder_id(conn: sqlite3.Connection) -> None:
    """Add folder_id to pre-folder-sync notebooks. NULL means unfiled."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(notebooks)")}
    if "folder_id" not in columns:
        conn.execute("ALTER TABLE notebooks ADD COLUMN folder_id TEXT")


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
        _migrate_jobs_request_id(conn)
        _migrate_jobs_result_segments(conn)
        _migrate_dumps_mode_check(conn)
        _migrate_dumps_meeting_notes(conn)
        _migrate_dumps_summary(conn)
        timing_backfills = _migrate_dumps_transcript_timings(conn)
        _migrate_notebooks_folder_id(conn)
        _migrate_change_log_folder_entity(conn)
        _migrate_change_log_ink_index_entity(conn)
        _migrate_notebooks_ink(conn)
        _normalize_notebooks_ink(conn)
        _reconcile_audio_kept(conn, data_dir)
        if timing_backfills:
            from app.api.dumps import _publish_dump_change

            prior_factory = conn.row_factory
            conn.row_factory = sqlite3.Row
            try:
                for dump_id in timing_backfills:
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
