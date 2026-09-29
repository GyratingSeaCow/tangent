# SPDX-License-Identifier: AGPL-3.0-or-later
from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from urllib.parse import quote

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.voices import router as voices_router
from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import voice_book as vb


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.execute(
        "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
        (hash_token(token), "TestUser", int(time.time())),
    )
    conn.commit()
    conn.close()
    app = FastAPI()
    app.include_router(voices_router)
    return TestClient(app), token


def _conn(temp_data_dir: Path) -> sqlite3.Connection:
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    c.row_factory = sqlite3.Row
    return c


def test_list_requires_auth(authed_client):
    client, _ = authed_client
    assert client.get("/v1/voices").status_code == 401


def test_list_shape_newest_first(authed_client, temp_data_dir):
    client, token = authed_client
    c = _conn(temp_data_dir)
    vb.teach(c, "Tom", [0.0, 1.0], now="2026-09-29T01:00:00Z")
    vb.teach(c, "Jeff O'Neil", [1.0, 0.0], now="2026-09-29T02:00:00Z")
    c.commit()
    r = client.get("/v1/voices", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json() == [
        {"name": "Jeff O'Neil", "samples": 1, "updated_at": "2026-09-29T02:00:00Z"},
        {"name": "Tom", "samples": 1, "updated_at": "2026-09-29T01:00:00Z"},
    ]
    assert "embedding" not in r.text


def test_delete_one_name_with_space_and_unicode(authed_client, temp_data_dir):
    client, token = authed_client
    c = _conn(temp_data_dir)
    vb.teach(c, "Zoë Smith", [1.0, 0.0])
    vb.teach(c, "Tom", [0.0, 1.0])
    c.commit()
    r = client.delete(
        f"/v1/voices/{quote('Zoë Smith')}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 204
    assert [e.name for e in vb.load_voice_book(c)] == ["Tom"]


def test_delete_unknown_404(authed_client):
    client, token = authed_client
    r = client.delete(
        "/v1/voices/Nobody", headers={"Authorization": f"Bearer {token}"}
    )
    assert r.status_code == 404
    assert r.json() == {"detail": "unknown voice"}
