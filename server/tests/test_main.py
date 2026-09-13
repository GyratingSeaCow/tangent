# SPDX-License-Identifier: AGPL-3.0-or-later
"""Integration test: full app boots, routes are mounted, setup flow works."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app


def test_app_boots_and_serves_setup(temp_data_dir: Path):
    app = create_app()
    client = TestClient(app)

    # GET /v1/server/info without auth → 401
    resp = client.get("/v1/server/info")
    assert resp.status_code == 401

    # POST /v1/setup → 200 with token
    resp = client.post("/v1/setup", json={"display_name": "Jeff"})
    assert resp.status_code == 200
    token = resp.json()["token"]
    assert len(token) >= 32

    # GET /v1/server/info with auth → 200
    resp = client.get("/v1/server/info", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["setup_complete"] is True


def test_app_lifespan_creates_data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("TANGENT_DATA_DIR", str(tmp_path / "fresh_data"))

    app = create_app()
    with TestClient(app):
        pass  # Lifespan runs on enter, cleanup on exit

    assert (tmp_path / "fresh_data").exists()
    assert (tmp_path / "fresh_data" / "tangent.db").exists()