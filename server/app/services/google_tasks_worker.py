# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Tasks REST client and periodic synchronization worker.

The API deliberately uses ``requests`` rather than Google's discovery client.
OAuth credentials and task mappings remain in SQLite and are never emitted in
the Tangent device-sync protocol.
"""

from __future__ import annotations

import sqlite3
import threading
from typing import Any

import requests

from app.logging_config import get_logger

log = get_logger(__name__)

TOKEN_URL = "https://oauth2.googleapis.com/token"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
TASKS_API = "https://tasks.googleapis.com/tasks/v1"
SYNC_INTERVAL_S = 5 * 60
REQUEST_TIMEOUT_S = 30


class GoogleTasksError(RuntimeError):
    """A sanitized Google HTTP failure safe to persist and show in settings."""

    def __init__(self, message: str, *, status_code: int | None = None, code: str | None = None):
        super().__init__(message[:500])
        self.status_code = status_code
        self.code = code


def _error_details(response: requests.Response) -> tuple[str | None, str | None]:
    try:
        body = response.json()
    except ValueError:
        return None, None
    if not isinstance(body, dict):
        return None, None
    error = body.get("error")
    if isinstance(error, dict):
        return str(error.get("status") or error.get("code") or "") or None, str(
            error.get("message") or ""
        ) or None
    if isinstance(error, str):
        return error, str(body.get("error_description") or "") or None
    return None, None


def _request(
    method: str,
    url: str,
    *,
    access_token: str | None = None,
    expected: tuple[int, ...] = (200,),
    **kwargs: Any,
) -> requests.Response:
    headers = dict(kwargs.pop("headers", {}))
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    try:
        response = requests.request(
            method,
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT_S,
            **kwargs,
        )
    except requests.RequestException as exc:
        raise GoogleTasksError(f"Google request failed: {type(exc).__name__}") from exc
    if response.status_code not in expected:
        code, detail = _error_details(response)
        message = detail or code or f"HTTP {response.status_code}"
        raise GoogleTasksError(
            f"Google request failed ({response.status_code}): {message}",
            status_code=response.status_code,
            code=code,
        )
    return response


def _json_object(response: requests.Response) -> dict[str, Any]:
    try:
        body = response.json()
    except ValueError as exc:
        raise GoogleTasksError("Google returned an invalid JSON response") from exc
    if not isinstance(body, dict):
        raise GoogleTasksError("Google returned a non-object JSON response")
    return body


def exchange_code(
    client_id: str,
    client_secret: str,
    code: str,
    redirect_uri: str,
) -> dict[str, Any]:
    """Exchange one authorization code without ever logging its secrets."""
    response = _request(
        "POST",
        TOKEN_URL,
        expected=(200,),
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
        },
    )
    return _json_object(response)


def revoke_token(token: str) -> None:
    """Best-effort caller-visible revoke; the API clears local tokens either way."""
    _request("POST", REVOKE_URL, expected=(200,), data={"token": token})


def ensure_tangent_tasklist(access_token: str) -> str:
    """Return the existing Tangent list id, or create exactly one."""
    page_token: str | None = None
    while True:
        params: dict[str, Any] = {"maxResults": 100}
        if page_token:
            params["pageToken"] = page_token
        body = _json_object(
            _request(
                "GET",
                f"{TASKS_API}/users/@me/lists",
                access_token=access_token,
                params=params,
            )
        )
        for item in body.get("items") or []:
            if isinstance(item, dict) and item.get("title") == "Tangent" and item.get("id"):
                return str(item["id"])
        raw_page = body.get("nextPageToken")
        page_token = str(raw_page) if raw_page else None
        if not page_token:
            break

    created = _json_object(
        _request(
            "POST",
            f"{TASKS_API}/users/@me/lists",
            access_token=access_token,
            expected=(200, 201),
            json={"title": "Tangent"},
        )
    )
    tasklist_id = created.get("id")
    if not tasklist_id:
        raise GoogleTasksError("Google did not return an id for the Tangent task list")
    return str(tasklist_id)


# The cycle/thread implementation lives below these OAuth helpers so tests can
# exercise the connection lifecycle without starting a background worker.
_cycle_lock = threading.Lock()
_stop = threading.Event()
_thread: threading.Thread | None = None


def run_cycle(db: sqlite3.Connection) -> tuple[int, int]:
    """Run one bidirectional cycle. Implemented in the sync feature commit."""
    del db
    return (0, 0)


def run_cycle_if_connected(db: sqlite3.Connection) -> bool:
    row = db.execute("SELECT status FROM google_tasks_link WHERE id = 1").fetchone()
    if row is None or row[0] != "connected":
        return False
    run_cycle(db)
    return True


def _worker_loop() -> None:
    import contextlib

    from app.db import get_db

    while not _stop.is_set():
        gen = get_db()
        db = next(gen)
        try:
            run_cycle_if_connected(db)
        except Exception:
            log.exception("google_tasks_worker.cycle_crashed")
        finally:
            with contextlib.suppress(StopIteration):
                next(gen)
        _stop.wait(SYNC_INTERVAL_S)


def worker_running() -> bool:
    return _thread is not None and _thread.is_alive()


def start_worker() -> threading.Thread:
    global _thread
    if worker_running():
        return _thread  # type: ignore[return-value]
    _stop.clear()
    _thread = threading.Thread(target=_worker_loop, name="google-tasks-worker", daemon=True)
    _thread.start()
    log.info("google_tasks_worker.started")
    return _thread


def stop_worker() -> None:
    global _thread
    if _thread is None:
        return
    _stop.set()
    _thread.join(timeout=5)
    _thread = None
    _stop.clear()
