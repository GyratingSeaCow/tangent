# SPDX-License-Identifier: AGPL-3.0-or-later
"""AI-summaries schema + sync plumbing (Task 2).

Three additive dump columns (summary, summary_model, summarized_at), the
server→client payload path, and the eraser rules: a client push must never
clear or set summary fields — absence is not an eraser, an explicit null is
not an eraser, and a client-sent value is not an authority.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import _publish_dump_change
from app.api.dumps import router as dumps_router
from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import SCHEMA, init_db


@pytest.fixture
def db(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(sync_router)
    app.include_router(dumps_router)
    return TestClient(app), token


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _insert_summarized_dump(conn: sqlite3.Connection, dump_id: str = "dump-sum") -> None:
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, summary, summary_model, "
        "summarized_at, audio_kept) "
        "VALUES (?, 'single-user', 1, 1, 'meeting', 60, 'Standup', "
        "'Sam: hello', '## Summary\nShort.', 'qwen-stem', 1700000000, 0)",
        (dump_id,),
    )
    conn.commit()


def _summary_row(conn: sqlite3.Connection, dump_id: str = "dump-sum") -> sqlite3.Row:
    return conn.execute(
        "SELECT summary, summary_model, summarized_at FROM dumps WHERE id = ?",
        (dump_id,),
    ).fetchone()


# ---------------------------------------------------------------------------
# schema: three additive nullable columns
# ---------------------------------------------------------------------------


def test_fresh_dumps_schema_has_nullable_summary_columns(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        cols = {row[1]: row for row in conn.execute("PRAGMA table_info(dumps)")}
    finally:
        conn.close()
    for name in ("summary", "summary_model", "summarized_at"):
        assert name in cols, f"dumps.{name} missing"
        assert cols[name][3] == 0, f"dumps.{name} must be nullable"
    assert cols["summary"][2] == "TEXT"
    assert cols["summary_model"][2] == "TEXT"
    assert cols["summarized_at"][2] == "INTEGER"


def test_legacy_dumps_table_gains_summary_columns_keeping_rows(
    temp_data_dir: Path,
):
    """A pre-summaries DB gains the columns via migration, rows intact."""
    db_path = temp_data_dir / "tangent.db"
    legacy = SCHEMA
    for line in (
        "    summary TEXT,\n",
        "    summary_model TEXT,\n",
        "    summarized_at INTEGER,\n",
    ):
        assert line in legacy, "fixture expects the column in SCHEMA"
        legacy = legacy.replace(line, "")
    conn = sqlite3.connect(db_path)
    conn.executescript(legacy)
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) "
        "VALUES ('dump-old', 'c', 1, 1, 'meeting', 5, 'Old', 'text', 0)"
    )
    conn.commit()
    pre = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    conn.close()
    assert "summary" not in pre, "fixture must start without the columns"

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # idempotent: no duplicate-column error

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT title, summary, summary_model, summarized_at "
            "FROM dumps WHERE id = 'dump-old'"
        ).fetchone()
    finally:
        conn.close()
    assert row["title"] == "Old"
    assert row["summary"] is None
    assert row["summary_model"] is None
    assert row["summarized_at"] is None


def test_app_settings_table_exists(temp_data_dir: Path):
    """Server-side persisted settings (the summaries toggle) live here."""
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO app_settings (key, value) VALUES ('k', 'v')"
        )
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# server→client: publish paths carry the summary fields
# ---------------------------------------------------------------------------


def test_publish_dump_change_payload_carries_summary_fields(db):
    _insert_summarized_dump(db)
    _publish_dump_change(db, "dump-sum", None)
    db.commit()

    row = db.execute(
        "SELECT payload FROM change_log WHERE entity_type = 'dump' "
        "AND entity_id = 'dump-sum' ORDER BY seq DESC"
    ).fetchone()
    payload = json.loads(row["payload"])
    assert payload["summary"] == "## Summary\nShort."
    assert payload["summary_model"] == "qwen-stem"
    assert payload["summarized_at"] == 1700000000


def test_dump_backfill_payload_carries_summary_fields(temp_data_dir: Path):
    """Recordings that predate the change feed get published with summaries."""
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        _insert_summarized_dump(conn, "dump-prefeed")
        # Wipe the feed entry created by nothing (init_db backfill runs on
        # empty dumps): remove any rows for this dump then re-init.
        conn.execute(
            "DELETE FROM change_log WHERE entity_id = 'dump-prefeed'"
        )
        conn.commit()
    finally:
        conn.close()

    init_db(str(temp_data_dir))  # backfill publishes the unseen dump

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-prefeed'"
        ).fetchone()
    finally:
        conn.close()
    assert row is not None
    payload = json.loads(row["payload"])
    assert payload["summary"] == "## Summary\nShort."
    assert payload["summary_model"] == "qwen-stem"
    assert payload["summarized_at"] == 1700000000


def test_sync_pull_delivers_summary_fields_to_other_devices(authed_client, db):
    """The whole server→client trip: publish, then a peer pulls the fields."""
    client, token = authed_client
    _insert_summarized_dump(db)
    _publish_dump_change(db, "dump-sum", "device-aaaa-1")
    db.commit()

    res = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_auth(token),
    )
    assert res.status_code == 200
    changes = [
        c for c in res.json()["changes"] if c["entity_id"] == "dump-sum"
    ]
    assert changes, "the peer must receive the dump change"
    payload = changes[-1]["payload"]
    assert payload["summary"] == "## Summary\nShort."
    assert payload["summary_model"] == "qwen-stem"
    assert payload["summarized_at"] == 1700000000


# ---------------------------------------------------------------------------
# push apply: client-sent summary keys are IGNORED, in every shape
# ---------------------------------------------------------------------------


def _push_dump(client, token, dump_id: str, payload: dict) -> dict:
    res = client.post(
        "/v1/sync/push",
        json={
            "device_id": "device-aaaa-1",
            "changes": [
                {
                    "entity_type": "dump",
                    "entity_id": dump_id,
                    "op": "upsert",
                    "payload": payload,
                }
            ],
        },
        headers=_auth(token),
    )
    assert res.status_code == 200
    return res.json()


def test_push_without_summary_keys_does_not_erase_summary(authed_client, db):
    """Absence is not an eraser: an older client's narrower payload must not
    clear a summary the server already generated."""
    client, token = authed_client
    _insert_summarized_dump(db)

    _push_dump(
        client, token, "dump-sum",
        {"title": "Renamed", "mode": "meeting", "duration_seconds": 60},
    )

    row = _summary_row(db)
    assert row["summary"] == "## Summary\nShort.", "absence is not an eraser"
    assert row["summary_model"] == "qwen-stem"
    assert row["summarized_at"] == 1700000000
    title = db.execute(
        "SELECT title FROM dumps WHERE id = 'dump-sum'"
    ).fetchone()["title"]
    assert title == "Renamed", "the push itself must still apply"


def test_push_with_explicit_null_summary_does_not_erase_summary(
    authed_client, db
):
    """An explicit null is not an eraser either: the client never owns these
    fields, so even a deliberate-looking null is ignored."""
    client, token = authed_client
    _insert_summarized_dump(db)

    _push_dump(
        client, token, "dump-sum",
        {
            "title": "Nulled",
            "summary": None,
            "summary_model": None,
            "summarized_at": None,
        },
    )

    row = _summary_row(db)
    assert row["summary"] == "## Summary\nShort.", "explicit null is not an eraser"
    assert row["summary_model"] == "qwen-stem"
    assert row["summarized_at"] == 1700000000


def test_push_with_client_sent_summary_value_is_ignored(authed_client, db):
    """Summaries are server-generated: a client-sent value must not land."""
    client, token = authed_client
    _insert_summarized_dump(db)

    _push_dump(
        client, token, "dump-sum",
        {
            "title": "Forged",
            "summary": "## Summary\nforged by a client",
            "summary_model": "evil-model",
            "summarized_at": 42,
        },
    )

    row = _summary_row(db)
    assert row["summary"] == "## Summary\nShort."
    assert row["summary_model"] == "qwen-stem"
    assert row["summarized_at"] == 1700000000


def test_push_republish_stamps_server_held_summary_fields(authed_client, db):
    """Like audio_kept: the feed echoes what the server HOLDS, so a device
    pushing a title edit does not broadcast a summary-less (or forged)
    payload to every other device."""
    client, token = authed_client
    _insert_summarized_dump(db)

    _push_dump(
        client, token, "dump-sum",
        {"title": "Edited", "summary": "forged"},
    )

    row = db.execute(
        "SELECT payload FROM change_log WHERE entity_type = 'dump' "
        "AND entity_id = 'dump-sum' ORDER BY seq DESC"
    ).fetchone()
    payload = json.loads(row["payload"])
    assert payload["summary"] == "## Summary\nShort."
    assert payload["summary_model"] == "qwen-stem"
    assert payload["summarized_at"] == 1700000000
