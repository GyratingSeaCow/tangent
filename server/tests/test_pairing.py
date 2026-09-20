# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pairing: a second device earns its own token by proving it can read the
server's output (the 6-digit code), never by copying a secret by hand."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.pairing import router as pairing_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def client(temp_data_dir: Path):
    # Module-global limiter and code cache leak across tests otherwise.
    import app.api.pairing as pairing_module

    pairing_module._request_log.clear()
    pairing_module._code_cache.clear()

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
    app.include_router(pairing_router)
    app.include_router(dumps_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _request_pairing(c, device_id="device-b-0001", name="Fold"):
    return c.post(
        "/v1/pair/request",
        json={"device_id": device_id, "display_name": name, "platform": "android"},
    )


def _pending_code(c, token, pair_id):
    rows = c.get("/v1/pair/pending", headers=_auth(token)).json()["pending"]
    return next(r["code"] for r in rows if r["pair_id"] == pair_id)


def test_request_returns_pair_id_but_never_the_code(client):
    c, _ = client
    resp = _request_pairing(c)
    assert resp.status_code == 201
    body = resp.json()
    assert body["pair_id"]
    assert body["expires_at"]
    assert "code" not in body, "the code must only be readable server-side"


def test_pending_lists_code_behind_auth_only(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]

    unauthed = c.get("/v1/pair/pending")
    assert unauthed.status_code == 401

    rows = c.get("/v1/pair/pending", headers=_auth(token)).json()["pending"]
    mine = next(r for r in rows if r["pair_id"] == pair_id)
    assert mine["display_name"] == "Fold"
    assert len(mine["code"]) == 6 and mine["code"].isdigit()


def test_correct_code_issues_working_token(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    code = _pending_code(c, token, pair_id)

    resp = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": code})
    assert resp.status_code == 200
    body = resp.json()
    assert body["server_name"] == "TestUser"
    assert body["device_id"] == "device-b-0001"

    # The minted token actually authenticates against a protected endpoint.
    check = c.get("/v1/dumps", headers=_auth(body["token"]))
    assert check.status_code == 200

    # And the original token still works: pairing adds, never replaces.
    assert c.get("/v1/dumps", headers=_auth(token)).status_code == 200


def test_wrong_code_counts_down_then_voids(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]

    for attempt in range(5):
        resp = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": "000000"})
        assert resp.status_code == 401
        assert resp.json()["detail"]["attempts_remaining"] == 4 - attempt

    # Voided: even the right code is dead now.
    code_row = c.get("/v1/pair/pending", headers=_auth(token)).json()["pending"]
    assert code_row == [], "a voided pairing must not stay listed"
    resp = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": "000000"})
    assert resp.status_code == 410


def test_expired_pairing_returns_410(client, monkeypatch):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    code = _pending_code(c, token, pair_id)

    import app.api.pairing as pairing_module

    real_time = time.time
    monkeypatch.setattr(
        pairing_module, "_now_ts", lambda: int(real_time()) + 121
    )
    resp = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": code})
    assert resp.status_code == 410


def test_claim_is_single_use(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    code = _pending_code(c, token, pair_id)

    first = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": code})
    assert first.status_code == 200
    second = c.post("/v1/pair/claim", json={"pair_id": pair_id, "code": code})
    assert second.status_code == 410, "a consumed pairing must not mint twice"


def test_repairing_same_device_revokes_previous_token(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    old = c.post(
        "/v1/pair/claim",
        json={"pair_id": pair_id, "code": _pending_code(c, token, pair_id)},
    ).json()["token"]
    assert c.get("/v1/dumps", headers=_auth(old)).status_code == 200

    pair_id2 = _request_pairing(c).json()["pair_id"]
    new = c.post(
        "/v1/pair/claim",
        json={"pair_id": pair_id2, "code": _pending_code(c, token, pair_id2)},
    ).json()["token"]

    assert c.get("/v1/dumps", headers=_auth(new)).status_code == 200
    assert c.get("/v1/dumps", headers=_auth(old)).status_code == 401, (
        "the same device pairing again must invalidate its old token"
    )


def test_revoking_device_kills_its_token(client):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    minted = c.post(
        "/v1/pair/claim",
        json={"pair_id": pair_id, "code": _pending_code(c, token, pair_id)},
    ).json()["token"]
    assert c.get("/v1/dumps", headers=_auth(minted)).status_code == 200

    resp = c.delete("/v1/devices/device-b-0001/token", headers=_auth(token))
    assert resp.status_code == 200
    assert c.get("/v1/dumps", headers=_auth(minted)).status_code == 401

    # The primary token is not revocable through this endpoint.
    assert c.get("/v1/dumps", headers=_auth(token)).status_code == 200


def test_request_rate_limited_per_source(client):
    c, _ = client
    for i in range(10):
        assert _request_pairing(c, device_id=f"spam-{i:04d}").status_code == 201
    resp = _request_pairing(c, device_id="spam-9999")
    assert resp.status_code == 429


def test_codes_are_stored_hashed(client, temp_data_dir):
    c, token = client
    pair_id = _request_pairing(c).json()["pair_id"]
    code = _pending_code(c, token, pair_id)

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        row = conn.execute(
            "SELECT code_hash FROM pairings WHERE pair_id = ?", (pair_id,)
        ).fetchone()
    finally:
        conn.close()
    assert row is not None
    assert code not in row[0], "raw code must never be stored"
