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
    # Google only accepts loopback redirect URIs for Desktop-app clients;
    # a LAN/Tailscale address produced "Error 400: invalid_request" on a
    # real device. TestClient calls us as http://testserver (port 80).
    assert query["redirect_uri"] == ["http://127.0.0.1:80/v1/google-tasks/callback"]
    return query["state"][0]


@pytest.mark.parametrize(
    "method,path",
    [
        ("get", "/v1/google-tasks/status"),
        ("post", "/v1/google-tasks/credentials"),
        ("post", "/v1/google-tasks/connect"),
        ("post", "/v1/google-tasks/disconnect"),
        ("post", "/v1/google-tasks/sync-now"),
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
    persisted = client.get("/v1/google-tasks/status", headers=_headers(token)).json()
    assert persisted["status"] == "disconnected"
    assert persisted["last_error"] == "OAuth state expired"


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


def _connected(db: sqlite3.Connection, *, expired: bool = False) -> None:
    db.execute(
        """
        INSERT OR REPLACE INTO google_tasks_link
            (id, client_id, client_secret, refresh_token, access_token,
             access_expires_at, tasklist_id, status)
        VALUES (1, 'client', 'secret', 'refresh', 'access', ?, 'list-1', 'connected')
        """,
        (int(time.time()) - 1 if expired else int(time.time()) + 3600,),
    )
    db.commit()


def _insert_todo(
    db: sqlite3.Connection,
    todo_id: str,
    *,
    text: str = "Buy milk",
    updated: str = "2026-09-27T12:00:00Z",
    done_at: str | None = None,
    due_date: str | None = "2026-09-28",
    deleted_at: str | None = None,
    google_id: str | None = None,
    google_updated: str | None = None,
) -> None:
    db.execute(
        """
        INSERT INTO todos
            (id, text, done_at, due_date, source, source_ref, folder_id,
             created_at, updated_at, deleted_at, google_task_id, google_updated)
        VALUES (?, ?, ?, ?, 'manual', NULL, NULL,
                '2026-09-27T11:00:00Z', ?, ?, ?, ?)
        """,
        (
            todo_id,
            text,
            done_at,
            due_date,
            updated,
            deleted_at,
            google_id,
            google_updated,
        ),
    )
    db.commit()


def test_mapping_due_and_done_both_directions():
    local = {
        "text": "Finish report",
        "due_date": "2026-09-30",
        "done_at": "2026-09-27T12:30:00Z",
    }
    mapped = google_tasks_worker.todo_to_google(local)
    assert mapped == {
        "title": "Finish report",
        "due": "2026-09-30T00:00:00.000Z",
        "status": "completed",
        "completed": "2026-09-27T12:30:00Z",
    }
    pending = google_tasks_worker.todo_to_google({**local, "done_at": None})
    assert pending["status"] == "needsAction"
    assert "completed" not in pending

    remote = google_tasks_worker.google_to_todo({
        "title": "From Google",
        "due": "2026-10-01T00:00:00.000Z",
        "status": "completed",
        "completed": "2026-09-27T14:00:00Z",
        "updated": "2026-09-27T14:01:00Z",
    })
    assert remote == {
        "text": "From Google",
        "due_date": "2026-10-01",
        "done_at": "2026-09-27T14:00:00Z",
    }


def test_push_creates_then_patches_instead_of_inserting_twice(
    google_api, monkeypatch
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(db, "todo-1")

        def first_cycle(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
            if method == "POST":
                assert url.endswith("/lists/list-1/tasks")
                assert kwargs["json"]["due"] == "2026-09-28T00:00:00.000Z"
                return FakeResponse(200, {
                    "id": "google-1", "updated": "2026-09-27T12:01:00Z",
                })
            assert method == "GET"
            return FakeResponse(200, {"items": []})

        calls = _install_fake_http(monkeypatch, first_cycle)
        assert google_tasks_worker.run_cycle(db) == (1, 0)
        assert [call[0] for call in calls] == ["POST", "GET"]
        row = db.execute("SELECT * FROM todos WHERE id='todo-1'").fetchone()
        assert row["google_task_id"] == "google-1"

        db.execute(
            "UPDATE todos SET text='Buy oat milk', updated_at=? WHERE id='todo-1'",
            ("2026-09-27T12:02:00Z",),
        )
        db.commit()

        def second_cycle(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
            if method == "PATCH":
                assert url.endswith("/lists/list-1/tasks/google-1")
                assert kwargs["json"]["title"] == "Buy oat milk"
                return FakeResponse(200, {
                    "id": "google-1", "updated": "2026-09-27T12:03:00Z",
                })
            assert method == "GET"
            return FakeResponse(200, {"items": []})

        calls = _install_fake_http(monkeypatch, second_cycle)
        assert google_tasks_worker.run_cycle(db) == (1, 0)
        assert [call[0] for call in calls] == ["PATCH", "GET"]


def test_pull_lww_google_newer_wins_local_newer_kept_equal_skipped(
    google_api, monkeypatch
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(
            db, "google-wins", text="old", updated="2026-09-27T12:00:00Z",
            google_id="g-new", google_updated="2026-09-27T12:00:00Z",
        )
        _insert_todo(
            db, "local-wins", text="local", updated="2026-09-27T14:00:00Z",
            google_id="g-old", google_updated="2026-09-27T14:00:00Z",
        )
        _insert_todo(
            db, "equal", text="equal-local", updated="2026-09-27T15:00:00Z",
            google_id="g-equal", google_updated="2026-09-27T14:59:00Z",
        )
        remote = [
            {"id": "g-new", "title": "google", "status": "needsAction",
             "updated": "2026-09-27T13:00:00Z"},
            {"id": "g-old", "title": "stale-google", "status": "needsAction",
             "updated": "2026-09-27T13:00:00Z"},
            {"id": "g-equal", "title": "equal-google", "status": "needsAction",
             "updated": "2026-09-27T15:00:00Z"},
        ]

        calls = _install_fake_http(
            monkeypatch,
            lambda method, url, kwargs: FakeResponse(200, {"items": remote}),
        )
        pulled, updated_min = google_tasks_worker._pull(db, "list-1", "access", None)
        assert pulled == 1
        assert updated_min == "2026-09-27T14:59:59.000Z"
        assert db.execute("SELECT text FROM todos WHERE id='google-wins'").fetchone()[0] == "google"
        assert db.execute("SELECT text FROM todos WHERE id='local-wins'").fetchone()[0] == "local"
        assert db.execute("SELECT text FROM todos WHERE id='equal'").fetchone()[0] == "equal-local"
        assert calls[0][2]["params"]["showDeleted"] == "true"
        assert db.execute(
            "SELECT COUNT(*) FROM change_log WHERE device_id='server'"
        ).fetchone()[0] == 1


def test_echo_guard_push_is_not_reapplied_by_following_pull(
    google_api, monkeypatch
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(db, "echo", text="Local title")

        def google(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
            if method == "POST":
                return FakeResponse(200, {
                    "id": "g-echo", "updated": "2026-09-27T12:01:00Z",
                })
            return FakeResponse(200, {"items": [{
                "id": "g-echo", "title": "Local title", "status": "needsAction",
                "updated": "2026-09-27T12:01:00Z",
            }]})

        _install_fake_http(monkeypatch, google)
        assert google_tasks_worker.run_cycle(db) == (1, 0)
        assert db.execute("SELECT text FROM todos WHERE id='echo'").fetchone()[0] == "Local title"
        assert db.execute(
            "SELECT COUNT(*) FROM change_log WHERE entity_id='echo'"
        ).fetchone()[0] == 0


def test_google_deleted_soft_deletes_and_records_server_change(
    google_api, monkeypatch
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(
            db, "deleted-by-google", google_id="g-delete",
            google_updated="2026-09-27T12:00:00Z",
        )
        calls = _install_fake_http(
            monkeypatch,
            lambda method, url, kwargs: FakeResponse(200, {"items": [{
                "id": "g-delete", "deleted": True,
                "updated": "2026-09-27T13:00:00Z",
            }]}),
        )
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT * FROM todos WHERE id='deleted-by-google'").fetchone()
        assert row["deleted_at"] == "2026-09-27T13:00:00Z"
        change = db.execute(
            "SELECT * FROM change_log WHERE entity_id='deleted-by-google'"
        ).fetchone()
        assert change["op"] == "delete"
        assert change["device_id"] == "server"
        assert change["payload"] is None
        assert calls[0][2]["params"]["showDeleted"] == "true"


@pytest.mark.parametrize("delete_status", [204, 404])
def test_tangent_soft_delete_calls_google_delete_tolerates_404_and_clears_id(
    google_api, monkeypatch, delete_status
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(
            db, "local-delete", deleted_at="2026-09-27T13:00:00Z",
            updated="2026-09-27T13:00:00Z", google_id="g-delete",
            google_updated="2026-09-27T12:00:00Z",
        )

        def google(method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
            if method == "DELETE":
                return FakeResponse(delete_status, {"error": {"message": "gone"}})
            return FakeResponse(200, {"items": []})

        calls = _install_fake_http(monkeypatch, google)
        assert google_tasks_worker.run_cycle(db) == (1, 0)
        assert calls[0][0] == "DELETE"
        assert db.execute(
            "SELECT google_task_id FROM todos WHERE id='local-delete'"
        ).fetchone()[0] is None


def test_unknown_google_task_creates_google_sourced_todo_and_change(
    google_api, monkeypatch
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _install_fake_http(
            monkeypatch,
            lambda method, url, kwargs: FakeResponse(200, {"items": [{
                "id": "g-new", "title": "Added in Google",
                "status": "completed", "completed": "2026-09-27T13:00:00Z",
                "due": "2026-09-30T00:00:00.000Z",
                "updated": "2026-09-27T13:01:00Z",
            }]}),
        )
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT * FROM todos WHERE google_task_id='g-new'").fetchone()
        assert row["source"] == "google"
        assert row["source_ref"] == "g-new"
        assert row["folder_id"] is None
        assert row["due_date"] == "2026-09-30"
        assert row["done_at"] == "2026-09-27T13:00:00Z"
        change = db.execute(
            "SELECT payload, device_id FROM change_log WHERE entity_id=?", (row["id"],)
        ).fetchone()
        assert change["device_id"] == "server"
        assert "google_task_id" not in change["payload"]


def test_invalid_grant_refresh_sets_reauth_required(google_api, monkeypatch):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db, expired=True)
        calls = _install_fake_http(
            monkeypatch,
            lambda method, url, kwargs: FakeResponse(
                400, {"error": "invalid_grant", "error_description": "expired"}
            ),
        )
        assert google_tasks_worker.run_cycle(db) == (0, 0)
        row = db.execute("SELECT status, last_error FROM google_tasks_link").fetchone()
        assert row["status"] == "reauth_required"
        assert "expired" in row["last_error"]
        assert len(calls) == 1


def test_sync_now_returns_last_cycle_counts(google_api, monkeypatch):
    client, token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_todo(db, "manual-sync")
    _install_fake_http(
        monkeypatch,
        lambda method, url, kwargs: (
            FakeResponse(200, {"id": "g-manual", "updated": "2026-09-27T12:01:00Z"})
            if method == "POST" else FakeResponse(200, {"items": []})
        ),
    )
    response = client.post("/v1/google-tasks/sync-now", headers=_headers(token))
    assert response.status_code == 200
    assert response.json()["status"] == "connected"
    assert response.json()["pushed"] == 1
    assert response.json()["pulled"] == 0
    assert response.json()["last_sync_at"] is not None


@pytest.mark.parametrize(
    "link_status", ["disconnected", "pending", "reauth_required", "error"]
)
def test_worker_skips_cycle_entirely_unless_connected(
    google_api, monkeypatch, link_status
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        db.execute(
            "INSERT OR REPLACE INTO google_tasks_link (id, status) VALUES (1, ?)",
            (link_status,),
        )
        db.commit()
        monkeypatch.setattr(
            google_tasks_worker,
            "run_cycle",
            lambda _db: pytest.fail("non-connected worker must skip the cycle"),
        )
        assert google_tasks_worker.run_cycle_if_connected(db) is False
    assert google_tasks_worker.SYNC_INTERVAL_S == 300


def test_worker_runs_one_cycle_when_connected(google_api, monkeypatch):
    _client, _token, db_path = google_api
    seen: list[sqlite3.Connection] = []
    with _db(db_path) as db:
        _connected(db)
        monkeypatch.setattr(
            google_tasks_worker, "run_cycle", lambda connection: seen.append(connection)
        )
        assert google_tasks_worker.run_cycle_if_connected(db) is True
        assert seen == [db]
