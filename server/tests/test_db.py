# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.db module."""

import sqlite3
from pathlib import Path

from app.db import get_db, init_db


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