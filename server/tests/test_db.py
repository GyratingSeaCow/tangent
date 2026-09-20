# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.db module."""

import sqlite3
from pathlib import Path

import pytest

from app.db import SCHEMA, get_db, init_db


def test_init_db_creates_sqlite_file(temp_data_dir: Path) -> None:
    db_path = temp_data_dir / "tangent.db"
    assert not db_path.exists()

    init_db(str(temp_data_dir))

    assert db_path.exists()


def test_init_db_creates_expected_tables(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        tables = {row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()}
    finally:
        conn.close()

    assert {"dumps", "jobs", "events", "auth"}.issubset(tables)


def test_init_db_is_idempotent(temp_data_dir: Path) -> None:
    """Calling init_db twice should not fail or duplicate tables."""
    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # Should not raise


def test_get_db_yields_connection_with_row_factory(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))

    conn_gen = get_db()
    conn = next(conn_gen)
    try:
        conn.execute("SELECT 1").fetchone()
    finally:
        try:
            next(conn_gen)
        except StopIteration:
            pass


def test_init_db_migrates_legacy_jobs_to_request_ids(temp_data_dir: Path) -> None:
    db_path = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA.replace("request_id TEXT NOT NULL,", ""))
    conn.executemany(
        "INSERT INTO jobs (id, dump_id, status, model) VALUES (?, ?, ?, ?)",
        [
            ("job-a", "dump-a", "queued", "large-v3"),
            ("job-b", "dump-b", "failed", "large-v3"),
        ],
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))

    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT id, request_id FROM jobs ORDER BY id").fetchall()
    columns = {row[1]: row for row in conn.execute("PRAGMA table_info(jobs)")}
    indexes = conn.execute("PRAGMA index_list('jobs')").fetchall()
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO jobs (id, request_id, dump_id, status, model) "
            "VALUES ('job-c', 'legacy:job-a', 'dump-c', 'queued', 'large-v3')"
        )
    conn.close()

    assert rows == [("job-a", "legacy:job-a"), ("job-b", "legacy:job-b")]
    assert columns["request_id"][3] == 0
    assert any(index[1] == "idx_jobs_request_id" and index[2] == 1 for index in indexes)


def test_fresh_jobs_schema_requires_request_id(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    columns = {row[1]: row for row in conn.execute("PRAGMA table_info(jobs)")}
    assert columns["request_id"][3] == 1
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO jobs (id, dump_id, status, model) "
            "VALUES ('job-no-request', 'dump-a', 'queued', 'large-v3')"
        )
    conn.close()


def test_fresh_jobs_schema_has_nullable_result_segments(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        columns = {row[1]: row for row in conn.execute("PRAGMA table_info(jobs)")}
    finally:
        conn.close()

    assert "result_segments" in columns
    # notnull flag must be 0 — segments are absent for queued/failed/legacy jobs.
    assert columns["result_segments"][3] == 0


def test_init_db_migrates_legacy_jobs_table_to_have_result_segments(
    temp_data_dir: Path,
) -> None:
    """A DB created before segments existed gains a nullable column, keeping its rows."""
    db_path = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA.replace("    result_segments TEXT,\n", ""))
    conn.execute(
        "INSERT INTO jobs (id, request_id, dump_id, status, model, result_transcript) "
        "VALUES ('job-old', 'request-old', 'dump-old', 'completed', 'large-v3', 'old text')"
    )
    conn.commit()
    pre_columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
    conn.close()
    assert "result_segments" not in pre_columns, "fixture must start without the column"

    init_db(str(temp_data_dir))

    conn = sqlite3.connect(db_path)
    try:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
        row = conn.execute(
            "SELECT result_transcript, result_segments FROM jobs WHERE id = 'job-old'"
        ).fetchone()
    finally:
        conn.close()

    assert "result_segments" in columns
    assert row == ("old text", None)


def test_init_db_segments_migration_is_idempotent(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # must not raise "duplicate column name"

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        columns = [row[1] for row in conn.execute("PRAGMA table_info(jobs)")]
    finally:
        conn.close()

    assert columns.count("result_segments") == 1


def test_dumps_table_has_expected_columns(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)").fetchall()}
    finally:
        conn.close()

    expected = {
        "id", "client_id", "created_at", "updated_at", "mode",
        "duration_seconds", "title", "transcript", "audio_kept",
    }
    assert expected.issubset(cols)


def test_init_db_migrates_dumps_mode_check_for_text_note(
    temp_data_dir: Path,
) -> None:
    """A legacy DB whose mode CHECK lacks text_note is rebuilt in place."""
    db_path = temp_data_dir / "tangent.db"
    legacy_schema = SCHEMA.replace("'meeting', 'text_note'", "'meeting'")
    assert "text_note" not in legacy_schema
    conn = sqlite3.connect(db_path)
    conn.executescript(legacy_schema)
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) "
        "VALUES ('dump-legacy', 'client-a', 1, 1, 'brain_dump', 60, "
        "'Legacy', NULL, 0)"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # migration must be idempotent

    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
            "duration_seconds, title, transcript, audio_kept) "
            "VALUES ('dump-note', 'client-a', 2, 2, 'text_note', 0, "
            "'Note', 'body', 0)"
        )
        rows = conn.execute(
            "SELECT id, mode FROM dumps ORDER BY created_at"
        ).fetchall()
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO dumps (id, client_id, created_at, updated_at, "
                "mode, duration_seconds, title, transcript, audio_kept) "
                "VALUES ('dump-bad', 'client-a', 3, 3, 'bogus', 0, 'X', "
                "NULL, 0)"
            )
        index_names = {
            row[1] for row in conn.execute("PRAGMA index_list('dumps')")
        }
    finally:
        conn.close()

    assert rows == [("dump-legacy", "brain_dump"), ("dump-note", "text_note")]
    assert {"idx_dumps_client_id", "idx_dumps_created_at"}.issubset(index_names)


def test_change_log_check_migration_preserves_seqs(tmp_path):
    """A pre-folder change_log (CHECK without 'folder') must be rebuilt
    in place with every seq intact — device checkpoints point into that
    sequence — and accept folder rows afterwards."""
    import sqlite3

    from app.db import init_db

    data = tmp_path / "data"
    data.mkdir()
    db_file = data / "tangent.db"
    conn = sqlite3.connect(db_file)
    conn.executescript(
        """
        CREATE TABLE change_log (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL
                CHECK (entity_type IN ('dump', 'notebook', 'note')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log
            (entity_type, entity_id, op, device_id, payload, created_at)
        VALUES ('notebook', 'nb-1', 'upsert', 'dev-1', '{}', 100),
               ('dump', 'd-1', 'upsert', 'dev-1', '{}', 101);
        """
    )
    conn.commit()
    conn.close()

    init_db(str(data))

    conn = sqlite3.connect(db_file)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT seq, entity_type FROM change_log ORDER BY seq"
    ).fetchall()
    assert [(r["seq"], r["entity_type"]) for r in rows][:2] == [
        (1, "notebook"),
        (2, "dump"),
    ], "existing seqs must survive the rebuild byte-for-byte"

    conn.execute(
        "INSERT INTO change_log "
        "(entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES ('folder', 'folder-1', 'upsert', 'dev-1', '{}', 102)"
    )
    new_seq = conn.execute("SELECT MAX(seq) FROM change_log").fetchone()[0]
    assert new_seq > 2, "AUTOINCREMENT must continue past copied rows"
    conn.close()
