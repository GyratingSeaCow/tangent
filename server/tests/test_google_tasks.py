# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Tasks server contract; every Google HTTP call is faked in-process."""

from __future__ import annotations

import json
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
    assert "https://www.googleapis.com/auth/calendar.events.owned" in query["scope"][0]
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
        "lists": [],
        "last_cycle": {"pushed": 0, "pulled": 0, "moved": 0},
        "calendar": {
            "enabled": False,
            "last_pushed": 0,
            "last_pulled": 0,
            "last_error": None,
        },
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
                    "scope": (
                        "https://www.googleapis.com/auth/tasks openid email "
                        "https://www.googleapis.com/auth/calendar.events.owned"
                    ),
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
        assert row["granted_scope"].split()[-1] == (
            "https://www.googleapis.com/auth/calendar.events.owned"
        )
        assert row["oauth_state"] is None
        assert connected["calendar"]["enabled"] is True


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
             access_expires_at, tasklist_id, status, granted_scope)
        VALUES (1, 'client', 'secret', 'refresh', 'access', ?, 'list-1', 'connected',
                'https://www.googleapis.com/auth/tasks')
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
        result = google_tasks_worker._pull(db, "list-1", "access", None)
        assert result.pulled == 1
        assert result.next_updated_min == "2026-09-27T14:59:59.000Z"
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
    assert response.json()["status"] == "reauth_required"
    assert response.json()["calendar"] == {
        "enabled": False,
        "last_pushed": 0,
        "last_pulled": 0,
        "last_error": "Google Calendar permission not granted — Reconnect",
    }
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


# ---------------------------------------------------------------------------
# v1.30 folders <-> Google lists (docs/design/2026-09-28-folders-google-lists.md)
# ---------------------------------------------------------------------------


def _insert_folder(
    db: sqlite3.Connection,
    folder_id: str,
    name: str,
    *,
    created_at: int = 1_700_000_000,
    deleted_at: int | None = None,
    tasklist_id: str | None = None,
) -> None:
    db.execute(
        "INSERT INTO folders (id, name, created_at, updated_at, deleted_at, "
        "google_tasklist_id) VALUES (?, ?, ?, ?, ?, ?)",
        (folder_id, name, created_at, created_at, deleted_at, tasklist_id),
    )
    db.commit()


def _set_todo_lists(db: sqlite3.Connection, **placements: tuple[str | None, str | None]) -> None:
    """placements: todo_id=(folder_id, google_tasklist_id)."""
    for todo_id, (folder_id, list_id) in placements.items():
        db.execute(
            "UPDATE todos SET folder_id = ?, google_tasklist_id = ? WHERE id = ?",
            (folder_id, list_id, todo_id),
        )
    db.commit()


def _api_path(url: str) -> str:
    assert url.startswith(google_tasks_worker.TASKS_API), url
    return url[len(google_tasks_worker.TASKS_API):]


def _path_list(url: str) -> str:
    return _api_path(url).split("/lists/")[1].split("/")[0]


def _path_task(url: str) -> str:
    return _api_path(url).split("/tasks/")[1].split("/")[0]


class FakeGoogle:
    """In-memory Google Tasks: lists, tasks, move, and a call log.

    Just enough of the REST surface for the worker: lists CRUD, tasks
    list/get/insert/patch/delete, and ``tasks.move`` with
    ``destinationTasklist`` (the task keeps its id).
    """

    def __init__(self, lists: dict[str, str] | None = None):
        self.lists: dict[str, str] = dict(lists or {"list-1": "Tangent"})
        self.tasks: dict[str, dict[str, dict[str, Any]]] = {k: {} for k in self.lists}
        self.calls: list[tuple[str, str, dict[str, Any]]] = []
        self.clock = 0
        self.fail_lists_get = False

    # -- helpers -----------------------------------------------------------
    def add_task(self, list_id: str, task_id: str, title: str, updated: str, **extra: Any) -> None:
        self.tasks.setdefault(list_id, {})[task_id] = {
            "id": task_id, "title": title, "status": "needsAction",
            "updated": updated, **extra,
        }

    def list_of(self, task_id: str) -> str | None:
        for list_id, tasks in self.tasks.items():
            if task_id in tasks:
                return list_id
        return None

    def _stamp(self) -> str:
        self.clock += 1
        return f"2026-09-28T10:{self.clock // 60:02d}:{self.clock % 60:02d}Z"

    def calls_of(self, method: str, fragment: str = "") -> list[tuple[str, str, dict[str, Any]]]:
        """Calls whose API path (after the /tasks/v1 prefix) contains ``fragment``."""
        return [c for c in self.calls if c[0] == method and fragment in _api_path(c[1])]

    # -- handler -----------------------------------------------------------
    def __call__(self, method: str, url: str, kwargs: dict[str, Any]) -> FakeResponse:
        self.calls.append((method, url, kwargs))
        parts = [p for p in _api_path(url).split("/") if p]
        if parts[:3] == ["users", "@me", "lists"]:
            if method == "GET":
                if self.fail_lists_get:
                    return FakeResponse(500, {"error": {"message": "boom"}})
                return FakeResponse(200, {"items": [
                    {"id": k, "title": v} for k, v in self.lists.items()
                ]})
            if method == "POST":
                new_id = f"list-{len(self.lists) + 1}"
                self.lists[new_id] = kwargs["json"]["title"]
                self.tasks[new_id] = {}
                return FakeResponse(200, {"id": new_id, "title": self.lists[new_id]})
            pytest.fail(f"unexpected {method} {url}")
        assert parts[0] == "lists", url
        list_id = parts[1]
        if len(parts) == 2:
            if list_id not in self.lists:
                return FakeResponse(404, {"error": {"message": "not found"}})
            if method == "PATCH":
                self.lists[list_id] = kwargs["json"]["title"]
                return FakeResponse(200, {"id": list_id, "title": self.lists[list_id]})
            if method == "DELETE":
                del self.lists[list_id]
                del self.tasks[list_id]
                return FakeResponse(204, {})
            pytest.fail(f"unexpected {method} {url}")
        assert parts[2] == "tasks", url
        if list_id not in self.lists:
            return FakeResponse(404, {"error": {"message": "list not found"}})
        tasks = self.tasks[list_id]
        if len(parts) == 3:
            if method == "GET":
                updated_min = (kwargs.get("params") or {}).get("updatedMin")
                items = [
                    t for t in tasks.values()
                    if not updated_min
                    or google_tasks_worker._parse_instant(t["updated"])
                    >= google_tasks_worker._parse_instant(updated_min)
                ]
                return FakeResponse(200, {"items": items})
            if method == "POST":
                task_id = f"g-{sum(len(t) for t in self.tasks.values()) + 1}"
                tasks[task_id] = {"id": task_id, **kwargs["json"], "updated": self._stamp()}
                return FakeResponse(200, tasks[task_id])
            pytest.fail(f"unexpected {method} {url}")
        task_id = parts[3]
        if len(parts) == 5 and parts[4] == "move":
            assert method == "POST"
            if task_id not in tasks:
                return FakeResponse(404, {"error": {"message": "task not found"}})
            dest = kwargs["params"]["destinationTasklist"]
            task = tasks.pop(task_id)
            task["updated"] = self._stamp()
            self.tasks[dest][task_id] = task
            return FakeResponse(200, task)
        if task_id not in tasks:
            return FakeResponse(404, {"error": {"message": "task not found"}})
        if method == "GET":
            return FakeResponse(200, tasks[task_id])
        if method == "PATCH":
            tasks[task_id].update(kwargs["json"])
            tasks[task_id]["updated"] = self._stamp()
            return FakeResponse(200, tasks[task_id])
        if method == "DELETE":
            del tasks[task_id]
            return FakeResponse(204, {})
        pytest.fail(f"unexpected {method} {url}")


@pytest.fixture
def fake_google(monkeypatch: pytest.MonkeyPatch) -> FakeGoogle:
    google = FakeGoogle()
    _install_fake_http(monkeypatch, google)
    return google


# -- ensure_lists (rules 1-3) -------------------------------------------------


def test_ensure_lists_creates_one_list_per_live_folder_named_like_it(google_api, fake_google):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Personal", created_at=1)
        _insert_folder(db, "f-work", "Work", created_at=2)
        _insert_folder(db, "f-gone", "Old", created_at=3, deleted_at=4)  # no list, never mapped
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        db.commit()
        assert fake_google.lists == {"list-1": "Tangent", "list-2": "Personal", "list-3": "Work"}
        assert managed == {"list-1": None, "list-2": "f-personal", "list-3": "f-work"}
        rows = db.execute(
            "SELECT id, google_tasklist_id FROM folders ORDER BY created_at"
        ).fetchall()
        assert [tuple(r) for r in rows] == [
            ("f-personal", "list-2"), ("f-work", "list-3"), ("f-gone", None),
        ]
        assert [c["json"]["title"] for _m, _u, c in fake_google.calls_of("POST", "/users/@me/lists")] == [
            "Personal", "Work",
        ]


def test_ensure_lists_readopts_existing_list_by_exact_title_and_ignores_foreign_lists(
    google_api, fake_google
):
    """Rule 1 re-adopt on reconnect; rule 3: 'Groceries' matches no folder and
    is left alone, and 'personal' (case differs) is not a match."""
    _client, _token, db_path = google_api
    fake_google.lists.update({"list-p": "Personal", "list-g": "Groceries", "list-lc": "personal"})
    fake_google.tasks.update({"list-p": {}, "list-g": {}, "list-lc": {}})
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Personal")
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        assert managed == {"list-1": None, "list-p": "f-personal"}
        assert fake_google.calls_of("POST") == []
        assert db.execute(
            "SELECT COUNT(*) FROM folders"
        ).fetchone()[0] == 1, "Google-only lists are not imported as folders"
        assert set(fake_google.lists) == {"list-1", "list-p", "list-g", "list-lc"}


def test_ensure_lists_dedupes_same_name_older_folder_owns_newer_gets_suffix(
    google_api, fake_google
):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-newer", "Errands", created_at=200)
        _insert_folder(db, "f-older", "Errands", created_at=100)
        _insert_folder(db, "f-third", "Errands", created_at=300)
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        by_folder = {v: fake_google.lists[k] for k, v in managed.items() if v}
        assert by_folder == {
            "f-older": "Errands", "f-newer": "Errands (2)", "f-third": "Errands (3)",
        }
        # Idempotent: a second run neither renames nor creates.
        before = len(fake_google.calls)
        assert google_tasks_worker.ensure_lists(db, "access", "list-1") == managed
        assert [c[0] for c in fake_google.calls[before:]] == ["GET"]


def test_ensure_lists_names_a_folder_called_tangent_with_suffix(google_api, fake_google):
    """The unfiled list owns the bare 'Tangent' title (L2)."""
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-t", "Tangent")
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        assert managed == {"list-1": None, "list-2": "f-t"}
        assert fake_google.lists["list-2"] == "Tangent (2)"


def test_ensure_lists_renames_google_list_when_folder_renamed(google_api, fake_google):
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Home", tasklist_id="list-p")
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        assert managed == {"list-1": None, "list-p": "f-personal"}
        patches = fake_google.calls_of("PATCH")
        assert len(patches) == 1
        assert patches[0][1].endswith("/lists/list-p")
        assert patches[0][2]["json"] == {"title": "Home"}
        assert fake_google.lists["list-p"] == "Home"
        assert fake_google.calls_of("POST") == []


def test_folder_delete_moves_tasks_to_unfiled_then_deletes_list(google_api, fake_google):
    """Rule 2 / L3: tasks survive folder deletion — moved to the unfiled list
    BEFORE the list is deleted, keeping their ids; mapping cleared."""
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    fake_google.add_task("list-p", "g-a", "A", "2026-09-27T12:00:00Z")
    fake_google.add_task("list-p", "g-b", "B", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Personal", deleted_at=5, tasklist_id="list-p")
        _insert_todo(db, "todo-a", text="A", google_id="g-a", google_updated="2026-09-27T12:00:00Z")
        _insert_todo(db, "todo-b", text="B", google_id="g-b", google_updated="2026-09-27T12:00:00Z")
        _set_todo_lists(db, **{"todo-a": ("f-personal", "list-p"), "todo-b": ("f-personal", "list-p")})
        db.execute("INSERT INTO google_list_cursor VALUES ('list-p', '2026-09-27T00:00:00Z')")
        db.commit()
        stats = google_tasks_worker.CycleStats()
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1", stats=stats)
        db.commit()
        assert managed == {"list-1": None}
        assert stats.moved == 2
        # Tasks survive folder deletion: same ids, now in the unfiled list.
        assert set(fake_google.tasks["list-1"]) == {"g-a", "g-b"}
        assert "list-p" not in fake_google.lists
        methods = [c[0] for c in fake_google.calls]
        assert methods.index("DELETE") > max(
            i for i, c in enumerate(fake_google.calls) if c[1].endswith("/move")
        ), "the list is deleted only after its tasks were moved out"
        move_calls = fake_google.calls_of("POST", "/move")
        assert {c[2]["params"]["destinationTasklist"] for c in move_calls} == {"list-1"}
        assert {_path_task(c[1]) for c in move_calls} == {"g-a", "g-b"}
        assert db.execute(
            "SELECT google_tasklist_id FROM folders WHERE id='f-personal'"
        ).fetchone()[0] is None
        assert db.execute(
            "SELECT COUNT(*) FROM google_list_cursor WHERE tasklist_id='list-p'"
        ).fetchone()[0] == 0
        rows = db.execute(
            "SELECT id, google_task_id, google_tasklist_id FROM todos ORDER BY id"
        ).fetchall()
        assert [tuple(r) for r in rows] == [
            ("todo-a", "g-a", "list-1"), ("todo-b", "g-b", "list-1"),
        ]


def test_folder_delete_treats_404_on_list_as_already_done(google_api, fake_google):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Personal", deleted_at=5, tasklist_id="list-gone")
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        assert managed == {"list-1": None}
        assert db.execute(
            "SELECT google_tasklist_id FROM folders WHERE id='f-personal'"
        ).fetchone()[0] is None
        assert fake_google.calls_of("DELETE") == []
        assert db.execute("SELECT status FROM google_tasks_link").fetchone()[0] == "connected"


def test_ensure_lists_readopts_when_mapped_list_was_deleted_in_google(google_api, fake_google):
    """Rule 1 re-adopt covers the mapped-but-vanished case too: a rename PATCH
    would 404, so the folder gets a fresh list rather than a failed cycle."""
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-personal", "Personal", tasklist_id="list-vanished")
        managed = google_tasks_worker.ensure_lists(db, "access", "list-1")
        assert managed == {"list-1": None, "list-2": "f-personal"}
        assert fake_google.lists["list-2"] == "Personal"


# -- push (rule 4) ------------------------------------------------------------


def test_push_new_task_lands_in_its_folders_list(google_api, fake_google):
    _client, _token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-shop", "Shop")
        _insert_todo(db, "filed", text="Buy milk")
        _insert_todo(db, "loose", text="Unfiled")
        _set_todo_lists(db, filed=("f-shop", None))
        assert google_tasks_worker.run_cycle(db) == (2, 0)
        filed = db.execute("SELECT * FROM todos WHERE id='filed'").fetchone()
        loose = db.execute("SELECT * FROM todos WHERE id='loose'").fetchone()
        shop_list = db.execute(
            "SELECT google_tasklist_id FROM folders WHERE id='f-shop'"
        ).fetchone()[0]
        assert shop_list == "list-2"
        assert fake_google.lists["list-2"] == "Shop"
        assert fake_google.list_of(filed["google_task_id"]) == "list-2"
        assert filed["google_tasklist_id"] == "list-2"
        assert fake_google.list_of(loose["google_task_id"]) == "list-1"
        assert loose["google_tasklist_id"] == "list-1"
        inserts = fake_google.calls_of("POST", "/tasks")
        assert [_path_list(c[1]) for c in inserts] == ["list-2", "list-1"]
        assert fake_google.calls_of("POST", "/move") == []


def test_push_folder_change_moves_same_task_id_then_patches(google_api, fake_google):
    """Rule 4: the recorded list differs from the target -> tasks.move with
    destinationTasklist, SAME task id (never delete+insert), then PATCH."""
    _client, _token, db_path = google_api
    fake_google.lists.update({"list-p": "Personal", "list-w": "Work"})
    fake_google.tasks.update({"list-p": {}, "list-w": {}})
    fake_google.add_task("list-p", "g-1", "Report", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", created_at=1, tasklist_id="list-p")
        _insert_folder(db, "f-w", "Work", created_at=2, tasklist_id="list-w")
        _insert_todo(
            db, "moved", text="Report v2", updated="2026-09-27T12:05:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, moved=("f-w", "list-p"))
        assert google_tasks_worker.run_cycle(db) == (1, 0)
        moves = fake_google.calls_of("POST", "/move")
        assert len(moves) == 1
        assert moves[0][1].endswith("/lists/list-p/tasks/g-1/move")
        assert moves[0][2]["params"] == {"destinationTasklist": "list-w"}
        assert fake_google.calls_of("DELETE") == []
        assert fake_google.calls_of("POST", "/tasks") == moves, "no insert, only the move"
        patches = fake_google.calls_of("PATCH")
        assert len(patches) == 1
        assert patches[0][1].endswith("/lists/list-w/tasks/g-1")
        assert patches[0][2]["json"]["title"] == "Report v2"
        assert fake_google.calls.index(moves[0]) < fake_google.calls.index(patches[0])
        row = db.execute("SELECT * FROM todos WHERE id='moved'").fetchone()
        assert row["google_task_id"] == "g-1", "SAME task id after the move"
        assert row["google_tasklist_id"] == "list-w"
        assert fake_google.list_of("g-1") == "list-w"
        assert fake_google.tasks["list-w"]["g-1"]["title"] == "Report v2"
        link = db.execute("SELECT last_moved, last_pushed FROM google_tasks_link").fetchone()
        assert tuple(link) == (1, 1)


def test_push_move_alone_when_only_folder_changed_records_echo_stamp(google_api, fake_google):
    """A folder-only change (no text edit newer than google_updated) still
    moves the task, and the move's ``updated`` is recorded (rule 8) so the
    next pull does not re-apply our own move."""
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    fake_google.add_task("list-1", "g-1", "Buy milk", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        _insert_todo(
            db, "t", updated="2026-09-27T12:00:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, t=("f-p", "list-1"))
        assert google_tasks_worker.run_cycle(db) == (0, 0)
        assert len(fake_google.calls_of("POST", "/move")) == 1
        assert fake_google.calls_of("PATCH") == []
        row = db.execute("SELECT * FROM todos WHERE id='t'").fetchone()
        assert row["google_tasklist_id"] == "list-p"
        assert row["google_updated"] == fake_google.tasks["list-p"]["g-1"]["updated"]
        assert row["folder_id"] == "f-p"
        assert db.execute("SELECT COUNT(*) FROM change_log").fetchone()[0] == 0
        # Second cycle: nothing to do — our own move is not pulled back.
        before = len(fake_google.calls)
        assert google_tasks_worker.run_cycle(db) == (0, 0)
        assert {c[0] for c in fake_google.calls[before:]} == {"GET"}
        assert db.execute("SELECT folder_id FROM todos WHERE id='t'").fetchone()[0] == "f-p"


def test_push_unfiled_todo_goes_to_unfiled_list_and_unfiling_moves_it_back(
    google_api, fake_google
):
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    fake_google.add_task("list-p", "g-1", "Was filed", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        _insert_todo(
            db, "now-unfiled", text="Was filed", updated="2026-09-27T12:01:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, **{"now-unfiled": (None, "list-p")})
        google_tasks_worker.run_cycle(db)
        moves = fake_google.calls_of("POST", "/move")
        assert len(moves) == 1
        assert moves[0][2]["params"] == {"destinationTasklist": "list-1"}
        assert fake_google.list_of("g-1") == "list-1"
        assert db.execute(
            "SELECT google_tasklist_id FROM todos WHERE id='now-unfiled'"
        ).fetchone()[0] == "list-1"


def test_push_todo_in_deleted_folder_is_moved_to_unfiled_list(google_api, fake_google):
    """Rule 4 'folder is live and mapped, else the unfiled list': the todo
    still says folder_id=f-gone, but that folder is soft-deleted."""
    _client, _token, db_path = google_api
    fake_google.lists["list-gone"] = "Gone"
    fake_google.tasks["list-gone"] = {}
    fake_google.add_task("list-gone", "g-1", "Orphan", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-gone", "Gone", deleted_at=9, tasklist_id="list-gone")
        _insert_todo(
            db, "orphan", text="Orphan", google_id="g-1",
            google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, orphan=("f-gone", "list-gone"))
        google_tasks_worker.run_cycle(db)
        assert fake_google.list_of("g-1") == "list-1"
        assert "list-gone" not in fake_google.lists
        row = db.execute("SELECT * FROM todos WHERE id='orphan'").fetchone()
        assert row["google_task_id"] == "g-1"
        assert row["google_tasklist_id"] == "list-1"
        assert db.execute("SELECT status FROM google_tasks_link").fetchone()[0] == "reauth_required"


def test_push_deletes_from_the_recorded_list(google_api, fake_google):
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    fake_google.add_task("list-p", "g-1", "Doomed", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        _insert_todo(
            db, "doomed", deleted_at="2026-09-27T13:00:00Z", updated="2026-09-27T13:00:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, doomed=("f-p", "list-p"))
        google_tasks_worker.run_cycle(db)
        deletes = fake_google.calls_of("DELETE")
        assert len(deletes) == 1 and deletes[0][1].endswith("/lists/list-p/tasks/g-1")
        assert "g-1" not in fake_google.tasks["list-p"]
        row = db.execute("SELECT google_task_id, google_tasklist_id FROM todos WHERE id='doomed'").fetchone()
        assert tuple(row) == (None, None)


# -- pull (rules 5-7) ---------------------------------------------------------


def test_pull_task_moved_between_lists_in_google_follows_into_folder(google_api, fake_google):
    """Rule 6 / L1: seen in Shop's list while recorded in the unfiled list ->
    folder_id follows, google_tasklist_id updated, server change_log row."""
    _client, _token, db_path = google_api
    fake_google.lists["list-shop"] = "Shop"
    fake_google.tasks["list-shop"] = {}
    fake_google.add_task("list-shop", "g-1", "Buy milk", "2026-09-27T13:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-shop", "Shop", tasklist_id="list-shop")
        _insert_todo(
            db, "milk", updated="2026-09-27T12:00:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _set_todo_lists(db, milk=(None, "list-1"))
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT * FROM todos WHERE id='milk'").fetchone()
        assert row["folder_id"] == "f-shop"
        assert row["google_tasklist_id"] == "list-shop"
        assert row["updated_at"] == "2026-09-27T13:00:00Z"
        change = db.execute(
            "SELECT device_id, op, payload FROM change_log WHERE entity_id='milk'"
        ).fetchone()
        assert change["device_id"] == "server"
        assert change["op"] == "upsert"
        payload = json.loads(change["payload"])
        assert payload["folder_id"] == "f-shop"
        assert "google_tasklist_id" not in payload and "google_task_id" not in payload
        assert db.execute("SELECT last_moved FROM google_tasks_link").fetchone()[0] == 1
        # And back to the unfiled list -> folder_id NULL.
        fake_google.tasks["list-1"]["g-1"] = fake_google.tasks["list-shop"].pop("g-1")
        fake_google.tasks["list-1"]["g-1"]["updated"] = "2026-09-27T14:00:00Z"
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT folder_id, google_tasklist_id FROM todos WHERE id='milk'").fetchone()
        assert tuple(row) == (None, "list-1")


def test_pull_lww_gate_blocks_google_move_older_than_local_edit(google_api, fake_google):
    """Rule 6 last sentence: a Google move whose ``updated`` is not newer than
    the local ``updated_at`` is NOT applied; Tangent's folder wins and the next
    push moves the task back where Tangent has it."""
    _client, _token, db_path = google_api
    fake_google.lists.update({"list-p": "Personal", "list-w": "Work"})
    fake_google.tasks.update({"list-p": {}, "list-w": {}})
    fake_google.add_task("list-w", "g-1", "Report", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", created_at=1, tasklist_id="list-p")
        _insert_folder(db, "f-w", "Work", created_at=2, tasklist_id="list-w")
        _insert_todo(
            db, "report", text="Report", updated="2026-09-27T12:30:00Z",
            google_id="g-1", google_updated="2026-09-27T12:30:00Z",
        )
        _set_todo_lists(db, report=("f-p", "list-p"))
        stats = google_tasks_worker.CycleStats()
        managed = {"list-1": None, "list-p": "f-p", "list-w": "f-w"}
        google_tasks_worker._pull_all(
            db, "access", managed, stats=stats,
            google_lists=google_tasks_worker._GoogleLists("access"),
        )
        row = db.execute("SELECT * FROM todos WHERE id='report'").fetchone()
        assert row["folder_id"] == "f-p", "older Google move must not undo the local filing"
        assert row["updated_at"] == "2026-09-27T12:30:00Z"
        assert stats.moved == 0 and stats.pulled == 0
        assert db.execute("SELECT COUNT(*) FROM change_log").fetchone()[0] == 0
        # Google's location is remembered so the follow-up push MOVES (same id).
        assert row["google_tasklist_id"] == "list-w"
        db.commit()
        google_tasks_worker.run_cycle(db)
        moves = fake_google.calls_of("POST", "/move")
        assert len(moves) == 1
        assert moves[0][1].endswith("/lists/list-w/tasks/g-1/move")
        assert moves[0][2]["params"] == {"destinationTasklist": "list-p"}
        assert fake_google.list_of("g-1") == "list-p"
        assert db.execute("SELECT folder_id FROM todos WHERE id='report'").fetchone()[0] == "f-p"


def test_pull_task_gone_from_all_managed_lists_becomes_unfiled(google_api, fake_google):
    """Rule 7: moved to an unmanaged list -> folder_id NULL + change_log row;
    the next push moves it back to the unfiled list (L1 second clause)."""
    _client, _token, db_path = google_api
    fake_google.lists.update({"list-p": "Personal", "list-x": "Not Tangent"})
    fake_google.tasks.update({"list-p": {}, "list-x": {}})
    fake_google.add_task("list-p", "g-stay", "Stays", "2026-09-27T13:00:00Z")
    fake_google.add_task("list-x", "g-1", "Wandered", "2026-09-27T13:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        _insert_todo(
            db, "wanderer", text="Wandered", updated="2026-09-27T12:00:00Z",
            google_id="g-1", google_updated="2026-09-27T12:00:00Z",
        )
        _insert_todo(
            db, "stayer", text="Stays", updated="2026-09-27T12:00:00Z",
            google_id="g-stay", google_updated="2026-09-27T13:00:00Z",
        )
        _set_todo_lists(db, wanderer=("f-p", "list-p"), stayer=("f-p", "list-p"))
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT * FROM todos WHERE id='wanderer'").fetchone()
        assert row["folder_id"] is None
        assert row["google_task_id"] == "g-1"
        change = db.execute(
            "SELECT payload FROM change_log WHERE entity_id='wanderer'"
        ).fetchone()
        assert json.loads(change["payload"])["folder_id"] is None
        gets = fake_google.calls_of("GET", "/tasks/g-1")
        assert gets and gets[0][1].endswith("/lists/list-p/tasks/g-1"), "confirmed via tasks.get 404"
        assert db.execute("SELECT folder_id FROM todos WHERE id='stayer'").fetchone()[0] == "f-p"
        # Next cycle: moved back into the unfiled list, same id.
        google_tasks_worker.run_cycle(db)
        assert fake_google.list_of("g-1") == "list-1"
        moves = fake_google.calls_of("POST", "/move")
        assert len(moves) == 1
        assert moves[0][2]["params"] == {"destinationTasklist": "list-1"}
        assert db.execute(
            "SELECT google_tasklist_id FROM todos WHERE id='wanderer'"
        ).fetchone()[0] == "list-1"


def test_pull_vanish_check_only_runs_for_lists_that_returned_a_delta(google_api, fake_google):
    """Rule 7 cost bound: no delta from the recorded list -> no full listing,
    no tasks.get; a mapped task the delta did not mention is left alone."""
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        _insert_todo(db, "quiet", google_id="g-1", google_updated="2026-09-27T12:00:00Z")
        _set_todo_lists(db, quiet=("f-p", "list-p"))
        assert google_tasks_worker.run_cycle(db) == (0, 0)
        assert fake_google.calls_of("GET", "/tasks/g-1") == []
        assert len(fake_google.calls_of("GET", "/lists/list-p/tasks")) == 1
        assert db.execute("SELECT folder_id FROM todos WHERE id='quiet'").fetchone()[0] == "f-p"


def test_pull_per_list_cursors_advance_independently(google_api, fake_google):
    _client, _token, db_path = google_api
    fake_google.lists["list-p"] = "Personal"
    fake_google.tasks["list-p"] = {}
    fake_google.add_task("list-1", "g-u", "Unfiled task", "2026-09-27T12:00:00Z")
    fake_google.add_task("list-p", "g-p", "Personal task", "2026-09-27T15:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal", tasklist_id="list-p")
        db.execute("INSERT INTO google_list_cursor VALUES ('list-1', '2026-09-27T11:00:00.000Z')")
        db.commit()
        assert google_tasks_worker.run_cycle(db) == (0, 2)
        cursors = dict(db.execute("SELECT * FROM google_list_cursor").fetchall())
        assert cursors == {
            "list-1": "2026-09-27T11:59:59.000Z",
            "list-p": "2026-09-27T14:59:59.000Z",
        }
        by_list = {
            _path_list(c[1]): (c[2].get("params") or {}).get("updatedMin")
            for c in fake_google.calls_of("GET", "/tasks")
        }
        assert by_list == {"list-1": "2026-09-27T11:00:00.000Z", "list-p": None}
        new_row = db.execute("SELECT folder_id FROM todos WHERE google_task_id='g-p'").fetchone()
        assert new_row["folder_id"] == "f-p", "a task created in Google inside Personal is filed there"
        # Only the unfiled list changes; only its cursor moves.
        fake_google.add_task("list-1", "g-u2", "Another", "2026-09-27T16:00:00Z")
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        cursors = dict(db.execute("SELECT * FROM google_list_cursor").fetchall())
        assert cursors == {
            "list-1": "2026-09-27T15:59:59.000Z",
            "list-p": "2026-09-27T14:59:59.000Z",
        }
        assert db.execute("SELECT last_pull_updated_min FROM google_tasks_link").fetchone()[0] is None


def test_migrated_link_cursor_is_used_as_the_unfiled_lists_updated_min(
    temp_data_dir, monkeypatch
):
    """The old single cursor migrates in (rule 5) and the first v1.30 pull of
    the unfiled list sends it as updatedMin — no full re-pull on upgrade."""
    init_db(str(temp_data_dir))
    db_path = temp_data_dir / "tangent.db"
    with _db(db_path) as db:
        _connected(db)
        db.execute(
            "UPDATE google_tasks_link SET last_pull_updated_min = '2026-09-27T09:00:00.000Z'"
        )
        db.execute("DELETE FROM google_list_cursor")
        db.commit()
    init_db(str(temp_data_dir))  # the upgrade
    google = FakeGoogle()
    _install_fake_http(monkeypatch, google)
    with _db(db_path) as db:
        assert dict(db.execute("SELECT * FROM google_list_cursor").fetchall()) == {
            "list-1": "2026-09-27T09:00:00.000Z"
        }
        google_tasks_worker.run_cycle(db)
        pulls = google.calls_of("GET", "/lists/list-1/tasks")
        assert pulls[0][2]["params"]["updatedMin"] == "2026-09-27T09:00:00.000Z"


def test_pull_google_task_created_in_a_folder_list_is_filed_there(google_api, fake_google):
    _client, _token, db_path = google_api
    fake_google.lists["list-w"] = "Work"
    fake_google.tasks["list-w"] = {}
    fake_google.add_task("list-w", "g-new", "New in Work", "2026-09-27T13:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-w", "Work", tasklist_id="list-w")
        assert google_tasks_worker.run_cycle(db) == (0, 1)
        row = db.execute("SELECT * FROM todos WHERE google_task_id='g-new'").fetchone()
        assert row["folder_id"] == "f-w"
        assert row["google_tasklist_id"] == "list-w"
        payload = json.loads(db.execute(
            "SELECT payload FROM change_log WHERE entity_id=?", (row["id"],)
        ).fetchone()[0])
        assert payload["folder_id"] == "f-w"
        assert "google_tasklist_id" not in payload


# -- full first cycle after deploy (Migration of the live data) ---------------


def test_first_cycle_after_upgrade_creates_folder_lists_and_moves_filed_todos(
    google_api, fake_google
):
    """Spec 'Migration of the live data': folders -> new lists, the filed todos
    move out of 'Tangent' (same ids), unfiled stay, nothing deleted."""
    _client, _token, db_path = google_api
    for n in range(1, 5):
        fake_google.add_task("list-1", f"g-{n}", f"Task {n}", "2026-09-27T12:00:00Z")
    with _db(db_path) as db:
        _connected(db)
        for i, name in enumerate(["Personal", "Work", "Bugs", "Shop"], start=1):
            _insert_folder(db, f"f-{name.lower()}", name, created_at=i)
        for n in range(1, 5):
            _insert_todo(
                db, f"t{n}", text=f"Task {n}", updated="2026-09-27T12:00:00Z",
                google_id=f"g-{n}", google_updated="2026-09-27T12:00:00Z",
            )
        # Pre-v1.30 rows have no recorded list (migration back-fills it, but
        # a NULL must also be understood as 'the unfiled list').
        _set_todo_lists(db, t1=("f-personal", None), t2=("f-shop", "list-1"))
        google_tasks_worker.run_cycle(db)
        assert set(fake_google.lists.values()) == {"Tangent", "Personal", "Work", "Bugs", "Shop"}
        lists_by_title = {v: k for k, v in fake_google.lists.items()}
        assert fake_google.list_of("g-1") == lists_by_title["Personal"]
        assert fake_google.list_of("g-2") == lists_by_title["Shop"]
        assert fake_google.list_of("g-3") == "list-1"
        assert fake_google.list_of("g-4") == "list-1"
        assert fake_google.calls_of("DELETE") == []
        assert len(fake_google.calls_of("POST", "/move")) == 2
        assert fake_google.calls_of("POST", "/tasks") == fake_google.calls_of("POST", "/move")
        assert db.execute("SELECT last_moved FROM google_tasks_link").fetchone()[0] == 2
        assert db.execute("SELECT COUNT(*) FROM change_log").fetchone()[0] == 0


# -- status (Endpoint change) -------------------------------------------------


def test_status_exposes_lists_and_last_cycle(google_api, fake_google):
    client, token, db_path = google_api
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-work", "Work", created_at=2)
        _insert_folder(db, "f-personal", "Personal", created_at=1)
        _insert_folder(db, "f-gone", "Gone", created_at=3, deleted_at=4)
        _insert_todo(db, "filed")
        _set_todo_lists(db, filed=("f-work", None))
    response = client.post("/v1/google-tasks/sync-now", headers=_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "reauth_required"
    assert body["calendar"]["last_error"] == (
        "Google Calendar permission not granted — Reconnect"
    )
    assert body["lists"] == [
        {"name": "Tangent", "tasklist_id": "list-1", "folder_id": None},
        {"name": "Personal", "tasklist_id": "list-2", "folder_id": "f-personal"},
        {"name": "Work", "tasklist_id": "list-3", "folder_id": "f-work"},
    ]
    assert body["last_cycle"] == {"pushed": 1, "pulled": 0, "moved": 0}
    assert body["pushed"] == 1 and body["pulled"] == 0
    for key in ("access_token", "refresh_token", "client_secret"):
        assert key not in json.dumps(body)
    status = client.get("/v1/google-tasks/status", headers=_headers(token)).json()
    assert status["lists"] == body["lists"]
    assert status["last_cycle"] == body["last_cycle"]


def test_ensure_lists_failure_marks_error_without_touching_todos(google_api, fake_google):
    _client, _token, db_path = google_api
    fake_google.fail_lists_get = True
    with _db(db_path) as db:
        _connected(db)
        _insert_folder(db, "f-p", "Personal")
        _insert_todo(db, "t")
        assert google_tasks_worker.run_cycle(db) == (0, 0)
        row = db.execute("SELECT status, last_error FROM google_tasks_link").fetchone()
        assert row["status"] == "error"
        assert "500" in row["last_error"]
        assert db.execute("SELECT google_task_id FROM todos WHERE id='t'").fetchone()[0] is None
