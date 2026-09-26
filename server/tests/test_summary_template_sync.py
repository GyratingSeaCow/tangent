# SPDX-License-Identifier: AGPL-3.0-or-later
"""summary_template schema, migration, dump response, and sync tests."""

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
            "VALUES (1, ?, 'Test', ?)",
            (hash_token(token), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    app = FastAPI()
    app.include_router(sync_router)
    app.include_router(dumps_router)
    return TestClient(app), token


def _insert(db: sqlite3.Connection, template: str | None = "lecture") -> None:
    db.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, summary_template, audio_kept) "
        "VALUES ('dump-template', 'single-user', 1, 1, 'meeting', 60, "
        "'Standup', 'Sam: hello', ?, 0)",
        (template,),
    )
    db.commit()


def test_fresh_schema_and_dump_response_expose_nullable_summary_template(
    authed_client, db
):
    cols = {row[1]: row for row in db.execute("PRAGMA table_info(dumps)")}
    assert cols["summary_template"][2] == "TEXT"
    assert cols["summary_template"][3] == 0
    _insert(db)

    client, token = authed_client
    response = client.get(
        "/v1/dumps/dump-template",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["summary_template"] == "lecture"


def test_legacy_schema_gains_template_and_republishes_null_sentinel(
    temp_data_dir: Path,
):
    """An existing feed row lacks the new key, so migration must republish."""
    db_path = temp_data_dir / "tangent.db"
    legacy = SCHEMA.replace("    summary_template TEXT,\n", "")
    assert legacy != SCHEMA
    conn = sqlite3.connect(db_path)
    conn.executescript(legacy)
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) "
        "VALUES ('dump-old-template', 'c', 1, 1, 'meeting', 5, 'Old', 'text', 0)"
    )
    conn.execute(
        "INSERT INTO change_log "
        "(entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES ('dump', 'dump-old-template', 'upsert', 'server', '{}', 1)"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # idempotent: do not publish repeatedly

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT summary_template FROM dumps WHERE id = 'dump-old-template'"
        ).fetchone()
        changes = conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-old-template' "
            "ORDER BY seq"
        ).fetchall()
    finally:
        conn.close()
    assert row["summary_template"] is None
    assert len(changes) == 2
    assert json.loads(changes[-1]["payload"])["summary_template"] is None


def test_publish_dump_change_carries_summary_template(db):
    _insert(db)
    _publish_dump_change(db, "dump-template", None)
    db.commit()
    raw = db.execute(
        "SELECT payload FROM change_log WHERE entity_id = 'dump-template' "
        "ORDER BY seq DESC"
    ).fetchone()["payload"]
    assert json.loads(raw)["summary_template"] == "lecture"


@pytest.mark.parametrize("sent", [None, "actions_only"])
def test_sync_push_cannot_clear_or_replace_server_held_template(
    authed_client, db, sent
):
    _insert(db)
    client, token = authed_client
    response = client.post(
        "/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "device_id": "device-aaaa-1",
            "changes": [
                {
                    "entity_type": "dump",
                    "entity_id": "dump-template",
                    "op": "upsert",
                    "payload": {"title": "Edited", "summary_template": sent},
                }
            ],
        },
    )
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "applied"
    row = db.execute(
        "SELECT summary_template FROM dumps WHERE id = 'dump-template'"
    ).fetchone()
    assert row["summary_template"] == "lecture"
    raw = db.execute(
        "SELECT payload FROM change_log WHERE entity_id = 'dump-template' "
        "ORDER BY seq DESC"
    ).fetchone()["payload"]
    assert json.loads(raw)["summary_template"] == "lecture"
