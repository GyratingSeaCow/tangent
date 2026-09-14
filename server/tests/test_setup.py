# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the /v1/setup endpoint."""

import sqlite3
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.setup import router
from app.db import init_db


@pytest.fixture
def client(temp_data_dir: Path) -> TestClient:
    init_db(str(temp_data_dir))
    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


def test_setup_returns_token_on_first_call(client: TestClient):
    resp = client.post(
        "/v1/setup",
        json={"display_name": "Jeff"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "token" in body
    assert len(body["token"]) >= 32
    assert body["display_name"] == "Jeff"
    assert "setup_completed_at" in body


def test_setup_no_new_token_after_first(client: TestClient):
    """First call returns the real token. Second call returns a placeholder.
    The token cannot be recovered from the hash."""
    resp1 = client.post("/v1/setup", json={"display_name": "Jeff"})
    resp2 = client.post("/v1/setup", json={"display_name": "Jeff"})

    assert resp1.status_code == 200
    assert resp2.status_code == 200
    # First call has real token
    assert "<token-issued" not in resp1.json()["token"]
    assert len(resp1.json()["token"]) >= 32
    # Second call returns placeholder
    assert "<token-issued" in resp2.json()["token"]


def test_setup_updates_display_name(client: TestClient):
    """Second call with different display_name updates it. Token is not recoverable after first call."""
    resp1 = client.post("/v1/setup", json={"display_name": "Jeff"})
    resp2 = client.post("/v1/setup", json={"display_name": "Jeffrey"})

    # First call has real token; second call returns placeholder
    assert "<token-issued" not in resp1.json()["token"]
    assert "<token-issued" in resp2.json()["token"]
    # Display name is updated
    assert resp2.json()["display_name"] == "Jeffrey"


def test_setup_handles_legacy_row_without_completion_timestamp(
    client: TestClient,
    temp_data_dir: Path,
):
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        db.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at, setup_completed_at) "
            "VALUES (1, ?, ?, ?, NULL)",
            ("existing-token-hash", "Legacy", 1),
        )
        db.commit()
    finally:
        db.close()

    resp = client.post("/v1/setup", json={"display_name": "Jeff"})

    assert resp.status_code == 200
    assert resp.json()["setup_completed_at"] is None


def test_setup_rejects_empty_display_name(client: TestClient):
    resp = client.post("/v1/setup", json={"display_name": ""})
    assert resp.status_code == 422


def test_setup_validates_payload(client: TestClient):
    resp = client.post("/v1/setup", json={})
    assert resp.status_code == 422
