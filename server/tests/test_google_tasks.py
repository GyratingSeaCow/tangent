# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Tasks server contract; every Google HTTP call is faked in-process."""

from __future__ import annotations

import sqlite3
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

import pytest
import requests
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.google_tasks import router as google_tasks_router
from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import google_tasks_worker


class FakeResponse:
    def __init__(self, status_code: int, body: dict[str, Any] | None = None):
        self.status_code = status_code
        self._body = body or {}

    def json(self) -> dict[str, Any]:
        return self._body


@pytest.fixture
def google_api(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    with sqlite3.connect(temp_data_dir / "tangent.db") as seed:
        seed.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
    app = FastAPI()
    app.include_router(google_tasks_router)
    with TestClient(app) as client:
        yield client, token, temp_data_dir / "tangent.db"


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _db(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    return db


def _install_fake_http(
    monkeypatch: pytest.MonkeyPatch,
    handler: Callable[[str, str, dict[str, Any]], FakeResponse],
) -> list[tuple[str, str, dict[str, Any]]]:
    calls: list[tuple[str, str, dict[str, Any]]] = []

    def fake_request(method: str, url: str, **kwargs: Any) -> FakeResponse:
        calls.append((method, url, kwargs))
        return handler(method, url, kwargs)

    monkeypatch.setattr(requests, "request", fake_request)
    return calls


def _save_and_start(client: TestClient, token: str) -> str:
    response = client.post(
        "/v1/google-tasks/credentials",
        json={"client_id": "desktop-client", "client_secret": "super-secret"},
        headers=_headers(token),
    )
    assert response.status_code == 200
    response = client.post("/v1/google-tasks/connect", headers=_headers(token))
    assert response.status_code == 200
    auth_url = response.json()["auth_url"]
    query = parse_qs(urlparse(auth_url).query)
    assert query["access_type"] == ["offline"]
    assert query["prompt"] == ["consent"]
    assert "https://www.googleapis.com/auth/tasks" in query["scope"][0]
    return query["state"][0]


@pytest.mark.parametrize(
    "method,path",
    [
        ("get", "/v1/google-tasks/status"),
        ("post", "/v1/google-tasks/credentials"),
        ("post", "/v1/google-tasks/connect"),
        ("post", "/v1/google-tasks/disconnect"),
    ],
)
def test_management_endpoints_require_bearer_auth(google_api, method, path):
    client, _token, _db_path = google_api
    if path.endswith("credentials"):
        response = client.post(path, json={})
    else:
        response = client.request(method.upper(), path)
    assert response.status_code == 401


def test_disconnected_connect_callback_connected_status(google_api, monkeypatch):
    client, token, db_path = google_api
    initial = client.get("/v1/google-tasks/status", headers=_headers(token)).json()
    assert initial == {
        "status": "disconnected",
        "credentials_configured": False,
        "google_email": None,
        "last_sync_at": None,
        "last_error": None,
        "pushed": 0,
        "pulled": 0,
    }
    state = _save_and_start(client, token)
    pending = client.get("/v1/google-tasks/status", headers=_headers(token)).json()
    assert pending["status"] == "pending"
    assert pending["credentials_configured"] is True

    def google(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
        if url == google_tasks_worker.TOKEN_URL:
            assert method == "POST"
            assert kwargs["data"]["code"] == "one-use-code"
            assert kwargs["data"]["client_secret"] == "super-secret"
            return FakeResponse(
                200,
                {
                    "access_token": "access-1",
                    "refresh_token": "refresh-1",
                    "expires_in": 3600,
                    "email": "jeff@example.test",
                },
            )
        assert method == "GET"
        assert url.endswith("/users/@me/lists")
        assert kwargs["headers"]["Authorization"] == "Bearer access-1"
        return FakeResponse(200, {"items": [{"id": "list-1", "title": "Tangent"}]})

    calls = _install_fake_http(monkeypatch, google)
    callback = client.get(
        "/v1/google-tasks/callback",
        params={"code": "one-use-code", "state": state},
    )
    assert callback.status_code == 200
    assert "Connected" in callback.text
    assert len(calls) == 2

    connected = client.get("/v1/google-tasks/status", headers=_headers(token)).json()
    assert connected["status"] == "connected"
    assert connected["google_email"] == "jeff@example.test"
    with _db(db_path) as db:
        row = db.execute("SELECT * FROM google_tasks_link WHERE id = 1").fetchone()
        assert row["tasklist_id"] == "list-1"
        assert row["refresh_token"] == "refresh-1"
        assert row["oauth_state"] is None


def test_callback_creates_tangent_list_when_missing(google_api, monkeypatch):
    client, token, _db_path = google_api
    state = _save_and_start(client, token)

    def google(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
        if url == google_tasks_worker.TOKEN_URL:
            return FakeResponse(200, {
                "access_token": "access", "refresh_token": "refresh", "expires_in": 60,
            })
        if method == "GET":
            return FakeResponse(200, {"items": [{"id": "other", "title": "Other"}]})
        assert method == "POST"
        assert kwargs["json"] == {"title": "Tangent"}
        return FakeResponse(201, {"id": "new-list", "title": "Tangent"})

    calls = _install_fake_http(monkeypatch, google)
    response = client.get(
        "/v1/google-tasks/callback", params={"code": "code", "state": state}
    )
    assert response.status_code == 200
    assert [call[0] for call in calls] == ["POST", "GET", "POST"]


def test_callback_rejects_mismatched_and_expired_state_without_google_http(
    google_api, monkeypatch
):
    client, token, db_path = google_api
    state = _save_and_start(client, token)

    def no_google(*_args: Any, **_kwargs: Any) -> FakeResponse:
        pytest.fail("invalid callback state must not make a Google HTTP call")

    monkeypatch.setattr(requests, "request", no_google)
    mismatch = client.get(
        "/v1/google-tasks/callback", params={"code": "code", "state": state + "x"}
    )
    assert mismatch.status_code == 400
    with _db(db_path) as db:
        db.execute(
            "UPDATE google_tasks_link SET oauth_state_expires_at = ? WHERE id = 1",
            (int(time.time()) - 1,),
        )
        db.commit()
    expired = client.get(
        "/v1/google-tasks/callback", params={"code": "code", "state": state}
    )
    assert expired.status_code == 400
    assert "expired" in expired.json()["detail"].lower()


def test_disconnect_revokes_and_clears_tokens_but_keeps_credentials(
    google_api, monkeypatch
):
    client, token, db_path = google_api
    client.post(
        "/v1/google-tasks/credentials",
        json={"client_id": "desktop-client", "client_secret": "super-secret"},
        headers=_headers(token),
    )
    with _db(db_path) as db:
        db.execute(
            "UPDATE google_tasks_link SET status='connected', refresh_token='refresh', "
            "access_token='access', tasklist_id='list' WHERE id=1"
        )
        db.commit()

    calls = _install_fake_http(
        monkeypatch,
        lambda method, url, kwargs: FakeResponse(200, {}),
    )
    response = client.post("/v1/google-tasks/disconnect", headers=_headers(token))
    assert response.status_code == 200
    assert response.json()["status"] == "disconnected"
    assert response.json()["credentials_configured"] is True
    assert calls[0][0:2] == ("POST", google_tasks_worker.REVOKE_URL)
    assert calls[0][2]["data"] == {"token": "refresh"}
    with _db(db_path) as db:
        row = db.execute("SELECT * FROM google_tasks_link WHERE id=1").fetchone()
        assert row["client_id"] == "desktop-client"
        assert row["client_secret"] == "super-secret"
        assert row["refresh_token"] is None
        assert row["access_token"] is None
        assert row["tasklist_id"] is None
