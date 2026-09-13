# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.auth module."""

import sqlite3
from pathlib import Path

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app.auth import generate_token, hash_token, require_auth
from app.db import init_db


@pytest.fixture
def app_with_auth(temp_data_dir: Path) -> TestClient:
    """Test app with /v1/protected endpoint that uses require_auth."""
    init_db(str(temp_data_dir))

    # Pre-seed the auth table with a known token
    raw_token = "test-token-abc123"
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, created_at) VALUES (1, ?, ?)",
            (hash_token(raw_token), 1700000000),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()

    @app.get("/v1/protected")
    def protected(user=Depends(require_auth)):
        return {"user": user}

    return TestClient(app)


def test_generate_token_returns_url_safe_string():
    token = generate_token()
    assert isinstance(token, str)
    assert len(token) >= 32
    # Should be URL-safe (no + or /)
    assert "+" not in token
    assert "/" not in token


def test_hash_token_is_deterministic():
    assert hash_token("abc") == hash_token("abc")


def test_hash_token_produces_64_char_hex():
    h = hash_token("any-string")
    assert len(h) == 64
    assert all(c in "0123456789abcdef" for c in h)


def test_require_auth_succeeds_with_valid_token(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected", headers={"Authorization": "Bearer test-token-abc123"})
    assert resp.status_code == 200


def test_require_auth_rejects_missing_header(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected")
    assert resp.status_code == 401


def test_require_auth_rejects_wrong_token(app_with_auth: TestClient):
    resp = app_with_auth.get(
        "/v1/protected", headers={"Authorization": "Bearer wrong-token"}
    )
    assert resp.status_code == 401


def test_require_auth_rejects_malformed_header(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected", headers={"Authorization": "test-token-abc123"})
    assert resp.status_code == 401


def test_require_auth_fails_when_no_token_configured(temp_data_dir: Path):
    """Server starts but auth table is empty → all requests rejected."""
    init_db(str(temp_data_dir))

    app = FastAPI()

    @app.get("/v1/protected")
    def protected(user=Depends(require_auth)):
        return {"user": user}

    client = TestClient(app)
    resp = client.get(
        "/v1/protected", headers={"Authorization": "Bearer anything"}
    )
    assert resp.status_code == 401