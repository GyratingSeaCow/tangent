# SPDX-License-Identifier: AGPL-3.0-or-later
"""Speaker-name rendering, schema migration, API response, and sync contract."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import SCHEMA, init_db
from app.services.speaker_names import render_speaker_names


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.execute(
        "INSERT INTO auth (id, token_hash, display_name, created_at) "
        "VALUES (1, ?, 'Test', ?)",
        (hash_token(token), int(time.time())),
    )
    conn.commit()
    conn.close()
    app = FastAPI()
    app.include_router(sync_router)
    app.include_router(dumps_router)
    return TestClient(app), token


def _push(client: TestClient, token: str, payload: dict):
    return client.post(
        "/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "device_id": "device-aaaa-1",
            "changes": [
                {
                    "entity_type": "dump",
                    "entity_id": "dump-speakers",
                    "op": "upsert",
                    "payload": payload,
                }
            ],
        },
    )


def test_render_speaker_names_only_changes_headings_and_line_prefixes():
    transcript = (
        "## Speaker 1\nSpeaker 1: Hello.\n"
        "Prose mentions Speaker 1: untouched.\n"
        "## Speaker 2\nSpeaker 2: Unmapped."
    )
    rendered = render_speaker_names(transcript, '{"Speaker 1":"Jeff"}')
    assert rendered == (
        "## Jeff\nJeff: Hello.\n"
        "Prose mentions Speaker 1: untouched.\n"
        "## Speaker 2\nSpeaker 2: Unmapped."
    )


@pytest.mark.parametrize("names", [None, "", "{}"])
def test_render_speaker_names_empty_map_is_identity(names):
    transcript = "## Speaker 1\nSpeaker 1: Hello."
    assert render_speaker_names(transcript, names) == transcript


def test_legacy_schema_gains_speaker_names_idempotently(temp_data_dir: Path):
    path = temp_data_dir / "tangent.db"
    legacy = SCHEMA.replace("    speaker_names TEXT,\n", "")
    assert legacy != SCHEMA
    conn = sqlite3.connect(path)
    conn.executescript(legacy)
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) VALUES "
        "('legacy-dump', 'c', 1, 1, 'meeting', 1, 'Old', 'text', 0)"
    )
    conn.execute(
        "INSERT INTO change_log "
        "(entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES ('dump', 'legacy-dump', 'upsert', 'server', '{}', 1)"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    columns = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    row = conn.execute(
        "SELECT speaker_names FROM dumps WHERE id = 'legacy-dump'"
    ).fetchone()
    changes = conn.execute(
        "SELECT payload FROM change_log WHERE entity_id = 'legacy-dump' ORDER BY seq"
    ).fetchall()
    conn.close()
    assert "speaker_names" in columns
    assert row["speaker_names"] is None
    assert len(changes) == 2
    assert json.loads(changes[-1]["payload"])["speaker_names"] is None


def test_sync_speaker_names_round_trip_absent_preserves_and_null_clears(
    authed_client, temp_data_dir: Path
):
    client, token = authed_client
    raw = '{"Speaker 1":"Jeff"}'
    base = {
        "client_id": "client-a",
        "mode": "meeting",
        "duration_seconds": 10,
        "title": "Standup",
        "transcript": "## Speaker 1\nSpeaker 1: Hi",
        "speaker_names": raw,
        "created_at": 1,
    }
    response = _push(client, token, base)
    assert response.status_code == 200

    response = _push(client, token, {"title": "Edited"})
    assert response.status_code == 200
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT speaker_names FROM dumps WHERE id = 'dump-speakers'"
    ).fetchone()
    payload = json.loads(
        conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-speakers' "
            "ORDER BY seq DESC"
        ).fetchone()["payload"]
    )
    assert row["speaker_names"] == raw
    assert payload["speaker_names"] == raw
    conn.close()

    detail = client.get(
        "/v1/dumps/dump-speakers",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert detail.status_code == 200
    assert detail.json()["speaker_names"] == raw

    response = _push(client, token, {"speaker_names": None})
    assert response.status_code == 200
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT speaker_names FROM dumps WHERE id = 'dump-speakers'"
    ).fetchone()
    payload = json.loads(
        conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-speakers' "
            "ORDER BY seq DESC"
        ).fetchone()["payload"]
    )
    conn.close()
    assert row["speaker_names"] is None
    assert payload["speaker_names"] is None


@pytest.mark.parametrize(
    "invalid",
    [
        {"Speaker 1": "Jeff"},
        "not-json",
        "[]",
        '{"Speaker 1":1}',
    ],
)
def test_invalid_speaker_names_returns_422(authed_client, invalid):
    client, token = authed_client
    response = _push(client, token, {"speaker_names": invalid})
    assert response.status_code == 422
