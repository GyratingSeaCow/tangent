# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Tasks REST client and periodic synchronization worker.

The API deliberately uses ``requests`` rather than Google's discovery client.
OAuth credentials and task mappings remain in SQLite and are never emitted in
the Tangent device-sync protocol.
"""

from __future__ import annotations

import sqlite3
import threading
import time
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import quote

import requests

from app.logging_config import get_logger
from app.services.change_log import record_change

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


_cycle_lock = threading.Lock()
_stop = threading.Event()
_thread: threading.Thread | None = None


def _parse_instant(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _rfc3339(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _now_rfc3339() -> str:
    return _rfc3339(datetime.now(UTC))


def _todo_payload(row: sqlite3.Row) -> dict[str, Any]:
    """Device-visible todo projection (never expose Google bookkeeping)."""
    return {
        "id": row["id"],
        "text": row["text"],
        "done_at": row["done_at"],
        "due_date": row["due_date"],
        "source": row["source"],
        "source_ref": row["source_ref"],
        "folder_id": row["folder_id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "deleted_at": row["deleted_at"],
    }


def todo_to_google(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
    """Map Tangent fields to the writable Google Task representation."""
    title = str(row["text"])
    if len(title) > 1024:
        title = title[:1023] + "…"
    payload: dict[str, Any] = {
        "title": title,
        "status": "completed" if row["done_at"] is not None else "needsAction",
    }
    if row["due_date"] is not None:
        payload["due"] = f"{row['due_date']}T00:00:00.000Z"
    if row["done_at"] is not None:
        payload["completed"] = row["done_at"]
    return payload


def google_to_todo(task: dict[str, Any]) -> dict[str, str | None]:
    """Map Google's writable fields back to Tangent todo fields."""
    updated = str(task["updated"])
    done_at = None
    if task.get("status") == "completed":
        done_at = str(task.get("completed") or updated)
    due = task.get("due")
    return {
        "text": str(task.get("title") or "Untitled"),
        "due_date": str(due)[:10] if due else None,
        "done_at": done_at,
    }


def _refresh_access_token(db: sqlite3.Connection, row: sqlite3.Row) -> str:
    access_token = row["access_token"]
    expires_at = row["access_expires_at"]
    if access_token and expires_at is not None and int(expires_at) > int(time.time()) + 60:
        return str(access_token)
    if not row["refresh_token"]:
        raise GoogleTasksError("Google refresh token is missing", code="invalid_grant")
    response = _request(
        "POST",
        TOKEN_URL,
        data={
            "client_id": row["client_id"],
            "client_secret": row["client_secret"],
            "refresh_token": row["refresh_token"],
            "grant_type": "refresh_token",
        },
    )
    tokens = _json_object(response)
    new_access = tokens.get("access_token")
    if not isinstance(new_access, str) or not new_access:
        raise GoogleTasksError("Google refresh response did not include an access token")
    expires_in = max(0, int(tokens.get("expires_in", 3600)))
    rotated_refresh = tokens.get("refresh_token") or row["refresh_token"]
    db.execute(
        "UPDATE google_tasks_link SET access_token = ?, access_expires_at = ?, "
        "refresh_token = ? WHERE id = 1",
        (new_access, int(time.time()) + expires_in, rotated_refresh),
    )
    return new_access


def _push(db: sqlite3.Connection, tasklist_id: str, access_token: str) -> int:
    rows = db.execute("SELECT * FROM todos ORDER BY id").fetchall()
    pushed = 0
    encoded_list = quote(tasklist_id, safe="")
    for row in rows:
        task_id = row["google_task_id"]
        if row["deleted_at"] is not None:
            if not task_id:
                continue
            _request(
                "DELETE",
                f"{TASKS_API}/lists/{encoded_list}/tasks/{quote(str(task_id), safe='')}",
                access_token=access_token,
                expected=(200, 204, 404),
            )
            db.execute(
                "UPDATE todos SET google_task_id = NULL WHERE id = ?", (row["id"],)
            )
            pushed += 1
            continue

        needs_push = not task_id or not row["google_updated"]
        if task_id and row["google_updated"]:
            needs_push = _parse_instant(row["updated_at"]) > _parse_instant(
                row["google_updated"]
            )
        if not needs_push:
            continue
        if task_id:
            response = _request(
                "PATCH",
                f"{TASKS_API}/lists/{encoded_list}/tasks/{quote(str(task_id), safe='')}",
                access_token=access_token,
                json=todo_to_google(row),
            )
        else:
            response = _request(
                "POST",
                f"{TASKS_API}/lists/{encoded_list}/tasks",
                access_token=access_token,
                expected=(200, 201),
                json=todo_to_google(row),
            )
        task = _json_object(response)
        returned_id = task.get("id") or task_id
        google_updated = task.get("updated")
        if not returned_id or not google_updated:
            raise GoogleTasksError("Google task write response omitted id or updated")
        db.execute(
            "UPDATE todos SET google_task_id = ?, google_updated = ? WHERE id = ?",
            (str(returned_id), str(google_updated), row["id"]),
        )
        pushed += 1
    return pushed


def _publish_todo(
    db: sqlite3.Connection,
    todo_id: str,
    *,
    op: str = "upsert",
) -> None:
    payload = None
    if op == "upsert":
        row = db.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
        if row is None:
            return
        payload = _todo_payload(row)
    record_change(
        db,
        entity_type="todo",
        entity_id=todo_id,
        op=op,
        device_id="server",
        payload=payload,
    )


def _apply_google_task(db: sqlite3.Connection, task: dict[str, Any]) -> bool:
    task_id = task.get("id")
    updated = task.get("updated")
    if not task_id or not updated:
        return False
    task_id = str(task_id)
    updated = str(updated)
    # Validate before any mutation; malformed remote timestamps must not poison
    # local LWW ordering.
    google_instant = _parse_instant(updated)
    existing = db.execute(
        "SELECT * FROM todos WHERE google_task_id = ?", (task_id,)
    ).fetchone()

    if task.get("deleted") is True:
        if existing is None:
            return False
        db.execute(
            "UPDATE todos SET google_updated = ? WHERE id = ?",
            (updated, existing["id"]),
        )
        if existing["deleted_at"] is not None:
            return False
        db.execute(
            "UPDATE todos SET deleted_at = ?, updated_at = ?, google_updated = ? "
            "WHERE id = ?",
            (updated, updated, updated, existing["id"]),
        )
        _publish_todo(db, existing["id"], op="delete")
        return True

    mapped = google_to_todo(task)
    if existing is None:
        todo_id = str(uuid.uuid4())
        db.execute(
            """
            INSERT INTO todos
                (id, text, done_at, due_date, source, source_ref, folder_id,
                 created_at, updated_at, deleted_at, google_task_id, google_updated)
            VALUES (?, ?, ?, ?, 'google', ?, NULL, ?, ?, NULL, ?, ?)
            """,
            (
                todo_id,
                mapped["text"],
                mapped["done_at"],
                mapped["due_date"],
                task_id,
                updated,
                updated,
                task_id,
                updated,
            ),
        )
        _publish_todo(db, todo_id)
        return True

    if existing["google_updated"] and google_instant == _parse_instant(
        existing["google_updated"]
    ):
        return False  # echo of our immediately preceding push
    local_instant = _parse_instant(existing["updated_at"])
    if google_instant <= local_instant:
        if google_instant == local_instant:
            db.execute(
                "UPDATE todos SET google_updated = ? WHERE id = ?",
                (updated, existing["id"]),
            )
        return False
    db.execute(
        """
        UPDATE todos SET text = ?, due_date = ?, done_at = ?,
            updated_at = ?, google_updated = ?, deleted_at = NULL
        WHERE id = ?
        """,
        (
            mapped["text"],
            mapped["due_date"],
            mapped["done_at"],
            updated,
            updated,
            existing["id"],
        ),
    )
    _publish_todo(db, existing["id"])
    return True


def _pull(
    db: sqlite3.Connection,
    tasklist_id: str,
    access_token: str,
    updated_min: str | None,
) -> tuple[int, str | None]:
    pulled = 0
    max_updated: datetime | None = None
    page_token: str | None = None
    encoded_list = quote(tasklist_id, safe="")
    while True:
        params: dict[str, Any] = {
            "maxResults": 100,
            "showCompleted": "true",
            "showHidden": "true",
            "showDeleted": "true",
        }
        if updated_min:
            params["updatedMin"] = updated_min
        if page_token:
            params["pageToken"] = page_token
        body = _json_object(
            _request(
                "GET",
                f"{TASKS_API}/lists/{encoded_list}/tasks",
                access_token=access_token,
                params=params,
            )
        )
        for raw_task in body.get("items") or []:
            if not isinstance(raw_task, dict):
                continue
            raw_updated = raw_task.get("updated")
            if raw_updated:
                instant = _parse_instant(str(raw_updated))
                max_updated = instant if max_updated is None else max(max_updated, instant)
            if _apply_google_task(db, raw_task):
                pulled += 1
        raw_page = body.get("nextPageToken")
        page_token = str(raw_page) if raw_page else None
        if not page_token:
            break
    next_updated_min = updated_min
    if max_updated is not None:
        next_updated_min = _rfc3339(max_updated - timedelta(seconds=1))
    return pulled, next_updated_min


def run_cycle(db: sqlite3.Connection) -> tuple[int, int]:
    """Run one push-then-pull LWW cycle and persist its public status."""
    with _cycle_lock:
        row = db.execute("SELECT * FROM google_tasks_link WHERE id = 1").fetchone()
        if row is None or row["status"] not in ("connected", "error"):
            return (0, 0)
        pushed = 0
        pulled = 0
        try:
            access_token = _refresh_access_token(db, row)
            if not row["tasklist_id"]:
                raise GoogleTasksError("Tangent Google task list is not configured")
            pushed = _push(db, str(row["tasklist_id"]), access_token)
            pulled, next_updated_min = _pull(
                db,
                str(row["tasklist_id"]),
                access_token,
                row["last_pull_updated_min"],
            )
            db.execute(
                """
                UPDATE google_tasks_link SET status = 'connected', last_error = NULL,
                    last_sync_at = ?, last_pushed = ?, last_pulled = ?,
                    last_pull_updated_min = ? WHERE id = 1
                """,
                (_now_rfc3339(), pushed, pulled, next_updated_min),
            )
            db.commit()
            log.info("google_tasks_worker.synced", pushed=pushed, pulled=pulled)
        except GoogleTasksError as exc:
            next_status = "reauth_required" if exc.code == "invalid_grant" else "error"
            db.execute(
                "UPDATE google_tasks_link SET status = ?, last_error = ?, "
                "last_pushed = ?, last_pulled = ? WHERE id = 1",
                (next_status, str(exc)[:500], pushed, pulled),
            )
            db.commit()
            log.warning(
                "google_tasks_worker.sync_failed",
                status=next_status,
                error=str(exc),
            )
        return pushed, pulled


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
