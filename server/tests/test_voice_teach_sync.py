# SPDX-License-Identifier: AGPL-3.0-or-later
"""A device rename teaches the voice book; only changed pairs."""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.sync import _teach_from_rename, router as sync_router
from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import voice_book as vb

DUMP = "dump-teach"


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.execute(
        "INSERT INTO auth (id, token_hash, display_name, created_at) "
        "VALUES (1, ?, ?, ?)",
        (hash_token(token), "TestUser", int(time.time())),
    )
    conn.commit()
    conn.close()
    app = FastAPI()
    app.include_router(sync_router)
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
                    "entity_id": DUMP,
                    "op": "upsert",
                    "payload": payload,
                }
            ],
        },
    )


def _seed(temp_data_dir: Path, embeddings: dict | None) -> sqlite3.Connection:
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds, "
        "title, transcript, speaker_embeddings, audio_kept) VALUES (?, 'c', 1, 1, 'meeting', 10, "
        "'Standup', '## Speaker 1\\nSpeaker 1: hi', ?, 1)",
        (DUMP, json.dumps(embeddings) if embeddings else None),
    )
    conn.commit()
    return conn


def test_rename_teaches_each_named_label(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0], "Speaker 2": [0.0, 1.0]})
    r = _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff", "Speaker 2": "Tom"})})
    assert r.status_code == 200
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert set(book) == {"Jeff", "Tom"}
    assert book["Jeff"].embedding == [1.0, 0.0] and book["Jeff"].samples == 1


def test_unchanged_pairs_do_not_bump_samples(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0], "Speaker 2": [0.0, 1.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff", "Speaker 2": "Tom"})})
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert book["Jeff"].samples == 1 and book["Tom"].samples == 1


def test_correction_removes_exact_taught_sample(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    vb.teach(conn, "Tom", [0.0, 1.0])
    conn.commit()
    assert _push(
        client, token, {"speaker_names": json.dumps({"Speaker 1": "Tom"})}
    ).status_code == 200

    assert _push(
        client, token, {"speaker_names": json.dumps({"Speaker 1": "Dana"})}
    ).status_code == 200
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert book["Tom"].embedding == pytest.approx([0.0, 1.0])
    assert book["Tom"].samples == 1
    assert book["Dana"].embedding == [1.0, 0.0] and book["Dana"].samples == 1


def test_correction_teaches_new_name_leaves_old_alone(authed_client, temp_data_dir):
    """An auto-name has no ledger entry, so its stored voice is untouched."""
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    vb.teach(conn, "Tom", [0.0, 1.0])
    conn.execute(
        "UPDATE dumps SET speaker_names = ? WHERE id = ?",
        (json.dumps({"Speaker 1": "Tom"}), DUMP),
    )
    conn.commit()

    assert _push(
        client, token, {"speaker_names": json.dumps({"Speaker 1": "Dana"})}
    ).status_code == 200
    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert book["Tom"].embedding == [0.0, 1.0]
    assert book["Tom"].samples == 1
    assert book["Dana"].samples == 1


def test_correction_deletes_old_name_when_last_sample_removed(
    authed_client, temp_data_dir
):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    assert _push(
        client, token, {"speaker_names": json.dumps({"Speaker 1": "Wrong"})}
    ).status_code == 200

    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})

    book = {e.name: e for e in vb.load_voice_book(conn)}
    assert "Wrong" not in book
    assert book["Jeff"].embedding == [1.0, 0.0]
    assert book["Jeff"].samples == 1


def test_unmapped_or_blank_or_no_embedding_teaches_nothing(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "  ", "Speaker 2": "Ghost"})})
    assert vb.load_voice_book(conn) == []


def test_same_map_resent_teaches_nothing(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    _push(client, token, {"title": "Edited"})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    assert vb.load_voice_book(conn)[0].samples == 1


def test_whitespace_only_change_does_not_reteach(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": " Jeff"})})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    assert vb.load_voice_book(conn)[0].samples == 1


def test_clearing_taught_name_unteaches_it(authed_client, temp_data_dir):
    client, token = authed_client
    conn = _seed(temp_data_dir, {"Speaker 1": [1.0, 0.0]})
    _push(client, token, {"speaker_names": json.dumps({"Speaker 1": "Jeff"})})
    r = _push(client, token, {"speaker_names": json.dumps({"Speaker 1": ""})})
    assert r.status_code == 200
    assert vb.load_voice_book(conn) == []
    assert conn.execute("SELECT count(*) FROM voice_book_samples").fetchone()[0] == 0


def test_null_stored_embedding_is_logged_and_skipped():
    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE TABLE voice_book (name TEXT PRIMARY KEY, embedding TEXT, "
        "samples INTEGER, updated_at TEXT)"
    )
    conn.execute(
        "CREATE TABLE voice_book_samples (dump_id TEXT, label TEXT, name TEXT, "
        "embedding TEXT, PRIMARY KEY (dump_id, label))"
    )
    conn.execute("INSERT INTO voice_book VALUES ('Tom', NULL, 1, 't')")
    conn.execute(
        "INSERT INTO voice_book_samples VALUES (?, ?, ?, ?)",
        (DUMP, "Speaker 1", "Tom", json.dumps([1.0, 0.0])),
    )
    result = _teach_from_rename(
        conn,
        DUMP,
        json.dumps({"Speaker 1": "Tom"}),
        json.dumps({"Speaker 1": "Dana"}),
        json.dumps({"Speaker 1": [1.0, 0.0]}),
    )
    assert result == ["Dana"]
    assert conn.execute("SELECT samples FROM voice_book WHERE name = 'Dana'").fetchone() == (1,)
