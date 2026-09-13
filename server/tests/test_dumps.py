# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/dumps endpoints."""

import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))

    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _make_dump_payload(idx: int = 0) -> dict:
    return {
        "id": f"dump-{idx:04d}-test-uuid",
        "mode": "brain_dump",
        "duration_seconds": 60,
        "title": f"Test dump {idx}",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def test_create_dump(authed_client):
    client, token = authed_client
    resp = client.post("/v1/dumps", json=_make_dump_payload(1), headers=_auth(token))
    assert resp.status_code == 201
    body = resp.json()
    assert body["id"] == "dump-0001-test-uuid"
    assert body["title"] == "Test dump 1"


def test_create_dump_requires_auth(authed_client):
    client, _ = authed_client
    resp = client.post("/v1/dumps", json=_make_dump_payload(1))
    assert resp.status_code == 401


def test_create_dump_is_idempotent_on_same_uuid(authed_client):
    client, token = authed_client
    payload = _make_dump_payload(2)
    resp1 = client.post("/v1/dumps", json=payload, headers=_auth(token))
    resp2 = client.post("/v1/dumps", json=payload, headers=_auth(token))
    assert resp1.status_code == 201
    assert resp2.status_code == 201


def test_list_dumps_returns_created(authed_client):
    client, token = authed_client
    for i in range(3):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))

    resp = client.get("/v1/dumps", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 3
    assert len(body["dumps"]) == 3


def test_list_dumps_supports_limit_and_offset(authed_client):
    client, token = authed_client
    for i in range(5):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))

    resp = client.get("/v1/dumps?limit=2&offset=1", headers=_auth(token))
    body = resp.json()
    assert len(body["dumps"]) == 2
    assert body["limit"] == 2
    assert body["offset"] == 1
    assert body["total"] == 5


def test_get_dump_by_id(authed_client):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(7), headers=_auth(token))

    resp = client.get("/v1/dumps/dump-0007-test-uuid", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["id"] == "dump-0007-test-uuid"


def test_get_unknown_dump_returns_404(authed_client):
    client, token = authed_client
    resp = client.get("/v1/dumps/does-not-exist", headers=_auth(token))
    assert resp.status_code == 404


def test_patch_dump_updates_title(authed_client):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(8), headers=_auth(token))

    resp = client.patch(
        "/v1/dumps/dump-0008-test-uuid",
        json={"title": "Renamed dump"},
        headers=_auth(token),
    )
    assert resp.status_code == 200
    assert resp.json()["title"] == "Renamed dump"


def test_delete_dump_soft_deletes(authed_client):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(9), headers=_auth(token))

    resp = client.delete("/v1/dumps/dump-0009-test-uuid", headers=_auth(token))
    assert resp.status_code == 204

    # Subsequent GET should 404
    resp = client.get("/v1/dumps/dump-0009-test-uuid", headers=_auth(token))
    assert resp.status_code == 404


def test_list_dumps_excludes_deleted(authed_client):
    client, token = authed_client
    for i in range(3):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))
    client.delete("/v1/dumps/dump-0001-test-uuid", headers=_auth(token))

    resp = client.get("/v1/dumps", headers=_auth(token))
    body = resp.json()
    assert body["total"] == 2