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
    mode TEXT NOT NULL CHECK (mode IN ('brain_dump', 'meeting')),
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    audio_kept INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_dumps_client_id ON dumps(client_id);
CREATE INDEX IF NOT EXISTS idx_dumps_created_at ON dumps(created_at DESC);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    dump_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    model TEXT NOT NULL,
    started_at INTEGER,
    completed_at INTEGER,
    result_transcript TEXT,
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
"""


def _db_path(data_dir: str) -> Path:
    return Path(data_dir) / "tangent.db"


def init_db(data_dir: str) -> None:
    """Create the SQLite DB and apply schema. Idempotent."""
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    path = _db_path(data_dir)
    is_new = not path.exists()

    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
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

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()