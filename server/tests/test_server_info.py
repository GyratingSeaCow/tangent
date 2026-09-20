# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/server/info, /v1/models, /v1/models/{name}/pull."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.models import router as models_router
from app.api.server_info import router as info_router
from app.auth import generate_token, hash_token
from app.db import init_db
from app.version import __version__


@pytest.fixture
def client(temp_data_dir: Path):
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
    app.include_router(info_router)
    app.include_router(models_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_server_info_returns_version(client):
    cli, token = client
    resp = cli.get("/v1/server/info", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == __version__
    assert body["setup_complete"] is True
    assert body["default_model"] == "large-v3"
    assert isinstance(body["available_models"], list)
    assert body["dump_count"] == 0


def test_server_info_requires_auth(client):
    cli, _ = client
    resp = cli.get("/v1/server/info")
    assert resp.status_code == 401


def test_list_models_returns_supported(client):
    cli, token = client
    resp = cli.get("/v1/models", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)
    assert "large-v3" in body


def test_pull_model_rejects_unknown(client):
    cli, token = client
    resp = cli.post("/v1/models/not-a-real-model/pull", headers=_auth(token))
    assert resp.status_code == 422


def test_pull_model_requires_auth(client):
    cli, _ = client
    resp = cli.post("/v1/models/large-v3/pull")
    assert resp.status_code == 401


def test_discovery_info_needs_no_auth(client):
    """The sweep identifies a server without credentials: minimal fields only."""
    c, _token = client
    resp = c.get("/v1/server/info/public")
    assert resp.status_code == 200
    body = resp.json()
    assert body["service"] == "tangent"
    assert body["version"] == __version__
    assert body["requires_auth"] is True
    assert "name" in body
    # Nothing private may leak on the unauthenticated form.
    for forbidden in ("storage_used_bytes", "dump_count", "available_models"):
        assert forbidden not in body


def test_discovery_info_reports_server_name(client):
    c, _token = client
    resp = c.get("/v1/server/info/public")
    assert resp.json()["name"] == "TestUser"
