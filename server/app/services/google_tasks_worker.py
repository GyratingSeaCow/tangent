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
from dataclasses import dataclass, field
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


UNFILED_LIST_TITLE = "Tangent"


@dataclass
class CycleStats:
    """Counters persisted as ``last_cycle`` (spec 2026-09-28, Endpoint change)."""

    pushed: int = 0
    pulled: int = 0
    moved: int = 0


@dataclass
class PullResult:
    pulled: int
    moved: int
    next_updated_min: str | None
    seen_ids: set[str] = field(default_factory=set)
    item_count: int = 0


class _GoogleLists:
    """Per-cycle view of ``GET users/@me/lists`` — fetched lazily, at most once."""

    def __init__(self, access_token: str):
        self._token = access_token
        self._items: dict[str, str] | None = None  # id -> title

    def items(self) -> dict[str, str]:
        if self._items is None:
            found: dict[str, str] = {}
            page_token: str | None = None
            while True:
                params: dict[str, Any] = {"maxResults": 100}
                if page_token:
                    params["pageToken"] = page_token
                body = _json_object(
                    _request(
                        "GET",
                        f"{TASKS_API}/users/@me/lists",
                        access_token=self._token,
                        params=params,
                    )
                )
                for item in body.get("items") or []:
                    if isinstance(item, dict) and item.get("id"):
                        found[str(item["id"])] = str(item.get("title") or "")
                raw_page = body.get("nextPageToken")
                page_token = str(raw_page) if raw_page else None
                if not page_token:
                    break
            self._items = found
        return self._items

    def title(self, list_id: str) -> str | None:
        return self.items().get(list_id)

    def find_by_title(self, title: str, *, exclude: set[str]) -> str | None:
        for list_id, list_title in self.items().items():
            if list_title == title and list_id not in exclude:
                return list_id
        return None

    def set_title(self, list_id: str, title: str) -> None:
        self.items()[list_id] = title

    def forget(self, list_id: str) -> None:
        if self._items is not None:
            self._items.pop(list_id, None)


def _list_url(list_id: str) -> str:
    return f"{TASKS_API}/lists/{quote(list_id, safe='')}"


def _task_url(list_id: str, task_id: str) -> str:
    return f"{_list_url(list_id)}/tasks/{quote(task_id, safe='')}"


def _list_tasks(
    access_token: str, list_id: str, updated_min: str | None
) -> list[dict[str, Any]] | None:
    """Every task in ``list_id`` (delta when ``updated_min``); None if the list is gone."""
    items: list[dict[str, Any]] = []
    page_token: str | None = None
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
        response = _request(
            "GET",
            f"{_list_url(list_id)}/tasks",
            access_token=access_token,
            params=params,
            expected=(200, 404),
        )
        if response.status_code == 404:
            return None
        body = _json_object(response)
        items.extend(t for t in body.get("items") or [] if isinstance(t, dict))
        raw_page = body.get("nextPageToken")
        page_token = str(raw_page) if raw_page else None
        if not page_token:
            break
    return items


def _get_task(access_token: str, list_id: str, task_id: str) -> dict[str, Any] | None:
    response = _request(
        "GET",
        _task_url(list_id, task_id),
        access_token=access_token,
        expected=(200, 404),
    )
    if response.status_code == 404:
        return None
    return _json_object(response)


def _move_task(
    access_token: str, source_list: str, task_id: str, destination_list: str
) -> dict[str, Any] | None:
    """``tasks.move`` with ``destinationTasklist`` — the task KEEPS its id
    (rule 4). None when the task is no longer in ``source_list`` (404)."""
    response = _request(
        "POST",
        f"{_task_url(source_list, task_id)}/move",
        access_token=access_token,
        params={"destinationTasklist": destination_list},
        expected=(200, 404),
    )
    if response.status_code == 404:
        return None
    return _json_object(response)


def _create_list(access_token: str, title: str) -> str:
    created = _json_object(
        _request(
            "POST",
            f"{TASKS_API}/users/@me/lists",
            access_token=access_token,
            expected=(200, 201),
            json={"title": title},
        )
    )
    list_id = created.get("id")
    if not list_id:
        raise GoogleTasksError(f"Google did not return an id for task list {title!r}")
    return str(list_id)


def _desired_titles(live_folders: list[sqlite3.Row]) -> dict[str, str]:
    """Rule 1 dedupe: the older ``created_at`` owns the bare name, the newer
    gets ``"<name> (2)"`` (then (3), ...). The unfiled list owns "Tangent"."""
    taken = {UNFILED_LIST_TITLE}
    titles: dict[str, str] = {}
    for folder in live_folders:
        base = str(folder["name"] or "Folder")
        title = base
        n = 2
        while title in taken:
            title = f"{base} ({n})"
            n += 1
        taken.add(title)
        titles[folder["id"]] = title
    return titles


def _retire_list(
    db: sqlite3.Connection,
    access_token: str,
    list_id: str,
    folder_id: str,
    unfiled_list_id: str,
    stats: CycleStats,
) -> None:
    """Rule 2 / L3: folder soft-deleted in Tangent. Move each task still in
    its list to the unfiled list, then DELETE the list. 404 = already done."""
    items = _list_tasks(access_token, list_id, None)
    if items is not None:
        for task in items:
            task_id = task.get("id")
            if not task_id or task.get("deleted") is True:
                continue
            moved = _move_task(access_token, list_id, str(task_id), unfiled_list_id)
            if moved is None:
                continue
            db.execute(
                "UPDATE todos SET google_tasklist_id = ?, "
                "google_updated = COALESCE(?, google_updated) WHERE google_task_id = ?",
                (unfiled_list_id, moved.get("updated"), str(task_id)),
            )
            stats.moved += 1
        _request(
            "DELETE",
            _list_url(list_id),
            access_token=access_token,
            expected=(200, 204, 404),
        )
    db.execute("UPDATE folders SET google_tasklist_id = NULL WHERE id = ?", (folder_id,))
    db.execute("DELETE FROM google_list_cursor WHERE tasklist_id = ?", (list_id,))
    # A todo still recorded in the retired list was not there to move. The
    # next push's move 404s and the rule-7 resolver finds where it went.
    log.info("google_tasks_worker.list_retired", folder_id=folder_id)


def ensure_lists(
    db: sqlite3.Connection,
    access_token: str,
    unfiled_list_id: str,
    *,
    stats: CycleStats | None = None,
    google_lists: _GoogleLists | None = None,
) -> dict[str, str | None]:
    """Rules 1-3: one Google list per live folder, named like the folder.

    Returns the managed lists as ``{tasklist_id: folder_id}`` with the unfiled
    list mapped to ``None``. Re-adopts by exact title on reconnect, creates
    what is missing, renames on folder rename, retires lists of soft-deleted
    folders. Lists in Google that match no folder are left alone (rule 3).
    """
    stats = stats if stats is not None else CycleStats()
    lists = google_lists if google_lists is not None else _GoogleLists(access_token)
    managed: dict[str, str | None] = {unfiled_list_id: None}
    folders = db.execute(
        "SELECT id, name, created_at, deleted_at, google_tasklist_id FROM folders "
        "ORDER BY created_at, id"
    ).fetchall()
    for folder in folders:
        if folder["deleted_at"] is not None and folder["google_tasklist_id"]:
            _retire_list(
                db, access_token, str(folder["google_tasklist_id"]),
                folder["id"], unfiled_list_id, stats,
            )
            lists.forget(str(folder["google_tasklist_id"]))
    live = [f for f in folders if f["deleted_at"] is None]
    if not live:
        return managed
    titles = _desired_titles(live)
    owned: set[str] = {unfiled_list_id}
    for folder in live:
        list_id = folder["google_tasklist_id"]
        if list_id and list_id != unfiled_list_id and list_id in lists.items():
            owned.add(str(list_id))
    for folder in live:
        title = titles[folder["id"]]
        list_id: str | None = folder["google_tasklist_id"]
        if list_id and (list_id == unfiled_list_id or list_id not in lists.items()):
            list_id = None  # deleted in Google (or corrupt): re-adopt or re-create
        if list_id and lists.title(list_id) != title:
            response = _request(
                "PATCH",
                _list_url(list_id),
                access_token=access_token,
                json={"title": title},
                expected=(200, 404),
            )
            if response.status_code == 404:
                lists.forget(list_id)
                owned.discard(list_id)
                list_id = None
            else:
                lists.set_title(list_id, title)
        if not list_id:
            list_id = lists.find_by_title(title, exclude=owned)
            if list_id is None:
                list_id = _create_list(access_token, title)
                lists.set_title(list_id, title)
            owned.add(list_id)
        if list_id != folder["google_tasklist_id"]:
            db.execute(
                "UPDATE folders SET google_tasklist_id = ? WHERE id = ?",
                (list_id, folder["id"]),
            )
        managed[list_id] = folder["id"]
    return managed


def _push(
    db: sqlite3.Connection,
    unfiled_list_id: str,
    access_token: str,
    *,
    folder_lists: dict[str, str] | None = None,
    stats: CycleStats | None = None,
) -> tuple[int, list[str]]:
    """Tangent -> Google (rule 4). Returns (pushed, ids that 404'd at their
    recorded list — the pull re-homes those, rule 6/7)."""
    stats = stats if stats is not None else CycleStats()
    if folder_lists is None:
        folder_lists = {
            row["id"]: str(row["google_tasklist_id"])
            for row in db.execute(
                "SELECT id, google_tasklist_id FROM folders "
                "WHERE deleted_at IS NULL AND google_tasklist_id IS NOT NULL"
            )
        }
    rows = db.execute("SELECT * FROM todos ORDER BY id").fetchall()
    pushed = 0
    stale: list[str] = []
    for row in rows:
        task_id = row["google_task_id"]
        # A mapped todo with no recorded list predates v1.30: it was pushed
        # into the unfiled list, so that is where Google has it.
        recorded = str(row["google_tasklist_id"] or unfiled_list_id)
        if row["deleted_at"] is not None:
            if not task_id:
                continue
            _request(
                "DELETE",
                _task_url(recorded, str(task_id)),
                access_token=access_token,
                expected=(200, 204, 404),
            )
            db.execute(
                "UPDATE todos SET google_task_id = NULL, google_tasklist_id = NULL "
                "WHERE id = ?",
                (row["id"],),
            )
            pushed += 1
            continue

        # Rule 4: the folder's list when the folder is live and mapped, else unfiled.
        target = folder_lists.get(row["folder_id"], unfiled_list_id) if row["folder_id"] else unfiled_list_id
        needs_push = not task_id or not row["google_updated"]
        if task_id and row["google_updated"]:
            needs_push = _parse_instant(row["updated_at"]) > _parse_instant(
                row["google_updated"]
            )
        if task_id and recorded != target:
            moved = _move_task(access_token, recorded, str(task_id), target)
            if moved is None:
                stale.append(row["id"])
                continue
            db.execute(
                "UPDATE todos SET google_tasklist_id = ?, "
                "google_updated = COALESCE(?, google_updated) WHERE id = ?",
                (target, moved.get("updated"), row["id"]),
            )
            stats.moved += 1
        if not needs_push:
            continue
        if task_id:
            response = _request(
                "PATCH",
                _task_url(target, str(task_id)),
                access_token=access_token,
                json=todo_to_google(row),
                expected=(200, 404),
            )
            if response.status_code == 404:
                stale.append(row["id"])
                continue
        else:
            response = _request(
                "POST",
                f"{_list_url(target)}/tasks",
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
            "UPDATE todos SET google_task_id = ?, google_updated = ?, "
            "google_tasklist_id = ? WHERE id = ?",
            (str(returned_id), str(google_updated), target, row["id"]),
        )
        pushed += 1
    stats.pushed += pushed
    return pushed, stale


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


def _apply_google_task(
    db: sqlite3.Connection,
    task: dict[str, Any],
    tasklist_id: str,
    folder_id: str | None,
) -> tuple[bool, bool]:
    """Apply one Google task seen in ``tasklist_id``. Returns (applied, moved).

    Rule 6: a task whose recorded list differs from ``tasklist_id`` was moved
    in Google — ``folder_id`` follows (NULL for the unfiled list) under the
    same LWW gate as every other field, so a same-second Tangent move wins.
    """
    task_id = task.get("id")
    updated = task.get("updated")
    if not task_id or not updated:
        return False, False
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
            return False, False
        db.execute(
            "UPDATE todos SET google_updated = ? WHERE id = ?",
            (updated, existing["id"]),
        )
        if existing["deleted_at"] is not None:
            return False, False
        db.execute(
            "UPDATE todos SET deleted_at = ?, updated_at = ?, google_updated = ? "
            "WHERE id = ?",
            (updated, updated, updated, existing["id"]),
        )
        _publish_todo(db, existing["id"], op="delete")
        return True, False

    mapped = google_to_todo(task)
    if existing is None:
        todo_id = str(uuid.uuid4())
        db.execute(
            """
            INSERT INTO todos
                (id, text, done_at, due_date, source, source_ref, folder_id,
                 created_at, updated_at, deleted_at, google_task_id, google_updated,
                 google_tasklist_id)
            VALUES (?, ?, ?, ?, 'google', ?, ?, ?, ?, NULL, ?, ?, ?)
            """,
            (
                todo_id,
                mapped["text"],
                mapped["done_at"],
                mapped["due_date"],
                task_id,
                folder_id,
                updated,
                updated,
                task_id,
                updated,
                tasklist_id,
            ),
        )
        _publish_todo(db, todo_id)
        return True, False

    # No recorded list means "the unfiled list" (pre-v1.30 rows), and the
    # unfiled list is the one pulled with folder_id None.
    recorded = existing["google_tasklist_id"]
    moved = recorded != tasklist_id and not (recorded is None and folder_id is None)
    if existing["google_updated"] and google_instant == _parse_instant(
        existing["google_updated"]
    ):
        # Echo of our immediately preceding write (rule 8). Our own moves
        # record the destination list, so a differing list here is a fact
        # about Google worth remembering, never a change to apply.
        if moved:
            db.execute(
                "UPDATE todos SET google_tasklist_id = ? WHERE id = ?",
                (tasklist_id, existing["id"]),
            )
        return False, False
    local_instant = _parse_instant(existing["updated_at"])
    if google_instant <= local_instant:
        if moved:
            # LWW blocks the Google move. Record where Google has the task
            # and clear the echo stamp so the next push moves it back to the
            # folder Tangent chose — the two sides must end up agreeing.
            db.execute(
                "UPDATE todos SET google_tasklist_id = ?, google_updated = NULL "
                "WHERE id = ?",
                (tasklist_id, existing["id"]),
            )
        elif google_instant == local_instant:
            db.execute(
                "UPDATE todos SET google_updated = ? WHERE id = ?",
                (updated, existing["id"]),
            )
        return False, False
    if moved:
        db.execute(
            """
            UPDATE todos SET text = ?, due_date = ?, done_at = ?, folder_id = ?,
                google_tasklist_id = ?, updated_at = ?, google_updated = ?,
                deleted_at = NULL
            WHERE id = ?
            """,
            (
                mapped["text"],
                mapped["due_date"],
                mapped["done_at"],
                folder_id,
                tasklist_id,
                updated,
                updated,
                existing["id"],
            ),
        )
    else:
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
    return True, moved


def _pull(
    db: sqlite3.Connection,
    tasklist_id: str,
    access_token: str,
    updated_min: str | None,
    folder_id: str | None = None,
) -> PullResult:
    """Delta-pull one managed list. The cursor is per list (rule 5)."""
    items = _list_tasks(access_token, tasklist_id, updated_min)
    if items is None:
        return PullResult(0, 0, updated_min)
    pulled = 0
    moved_count = 0
    max_updated: datetime | None = None
    seen: set[str] = set()
    for raw_task in items:
        if raw_task.get("id"):
            seen.add(str(raw_task["id"]))
        raw_updated = raw_task.get("updated")
        if raw_updated:
            instant = _parse_instant(str(raw_updated))
            max_updated = instant if max_updated is None else max(max_updated, instant)
        applied, moved = _apply_google_task(db, raw_task, tasklist_id, folder_id)
        if applied:
            pulled += 1
        if moved:
            moved_count += 1
    next_updated_min = updated_min
    if max_updated is not None:
        next_updated_min = _rfc3339(max_updated - timedelta(seconds=1))
    return PullResult(pulled, moved_count, next_updated_min, seen, len(items))


def _resolve_vanished(
    db: sqlite3.Connection,
    access_token: str,
    row: sqlite3.Row,
    managed: dict[str, str | None],
    google_lists: _GoogleLists,
    stats: CycleStats,
) -> None:
    """Rule 7: ``row``'s task is absent from its recorded list's listing.

    Confirm with ``tasks.get`` (404). If it turns up in another managed list
    that is a Google move (rule 6). Otherwise it went to an unmanaged list
    (or was purged): treat as unfiled — ``folder_id = NULL`` — and remember
    the list it landed in so the next push can ``move`` it back to the
    unfiled list (rule 4) rather than duplicate it.
    """
    unfiled_list_id = next(k for k, v in managed.items() if v is None)
    task_id = str(row["google_task_id"])
    recorded = str(row["google_tasklist_id"] or unfiled_list_id)
    if _get_task(access_token, recorded, task_id) is not None:
        return  # still there — the listing was a snapshot race
    for list_id, folder_id in managed.items():
        if list_id == recorded:
            continue
        task = _get_task(access_token, list_id, task_id)
        if task is not None:
            applied, moved = _apply_google_task(db, task, list_id, folder_id)
            stats.pulled += int(applied)
            stats.moved += int(moved)
            return
    found: str | None = None
    for list_id in google_lists.items():
        if list_id in managed or list_id == recorded:
            continue
        if _get_task(access_token, list_id, task_id) is not None:
            found = list_id
            break
    now = _now_rfc3339()
    if found:
        db.execute(
            "UPDATE todos SET folder_id = NULL, google_tasklist_id = ?, updated_at = ?, "
            "google_updated = NULL WHERE id = ?",
            (found, now, row["id"]),
        )
    else:
        db.execute(
            "UPDATE todos SET folder_id = NULL, google_tasklist_id = NULL, "
            "google_task_id = NULL, google_updated = NULL, updated_at = ? WHERE id = ?",
            (now, row["id"]),
        )
    _publish_todo(db, row["id"])
    stats.pulled += 1
    log.info("google_tasks_worker.task_unfiled", todo_id=row["id"], found=bool(found))


def _pull_all(
    db: sqlite3.Connection,
    access_token: str,
    managed: dict[str, str | None],
    *,
    stats: CycleStats,
    google_lists: _GoogleLists,
    stale_ids: list[str] | None = None,
) -> int:
    """Rule 5: pull every managed list with its own cursor; then rule 7."""
    pulled = 0
    unfiled_list_id = next(k for k, v in managed.items() if v is None)
    candidates: list[tuple[str, str, str]] = []  # (todo_id, task_id, recorded list)
    for list_id, folder_id in managed.items():
        cursor = db.execute(
            "SELECT updated_min FROM google_list_cursor WHERE tasklist_id = ?",
            (list_id,),
        ).fetchone()
        result = _pull(db, list_id, access_token, cursor[0] if cursor else None, folder_id)
        pulled += result.pulled
        stats.moved += result.moved
        db.execute(
            "INSERT OR REPLACE INTO google_list_cursor (tasklist_id, updated_min) "
            "VALUES (?, ?)",
            (list_id, result.next_updated_min),
        )
        if not result.item_count:
            continue  # rule 7 checks only lists that returned a delta
        unseen = [
            r
            for r in db.execute(
                "SELECT id, google_task_id FROM todos "
                "WHERE COALESCE(google_tasklist_id, ?) = ? "
                "AND google_task_id IS NOT NULL AND deleted_at IS NULL",
                (unfiled_list_id, list_id),
            )
            if str(r["google_task_id"]) not in result.seen_ids
        ]
        if not unseen:
            continue
        full = _list_tasks(access_token, list_id, None) or []
        present = {str(t["id"]) for t in full if t.get("id")}
        candidates.extend(
            (r["id"], str(r["google_task_id"]), list_id)
            for r in unseen
            if str(r["google_task_id"]) not in present
        )
    for todo_id in stale_ids or []:
        row = db.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
        if row is not None and row["google_task_id"]:
            candidates.append((
                todo_id, str(row["google_task_id"]),
                str(row["google_tasklist_id"] or unfiled_list_id),
            ))
    stats.pulled += pulled
    resolved: set[str] = set()
    for todo_id, task_id, recorded in candidates:
        if todo_id in resolved:
            continue
        row = db.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
        if (
            row is None
            or row["deleted_at"] is not None
            or row["google_task_id"] != task_id
            or (row["google_tasklist_id"] or unfiled_list_id) != recorded
        ):
            continue  # re-homed by a later list's pull, or gone
        resolved.add(todo_id)
        _resolve_vanished(db, access_token, row, managed, google_lists, stats)
    return stats.pulled


def run_cycle(db: sqlite3.Connection) -> tuple[int, int]:
    """Run one ensure-lists / push / pull LWW cycle and persist its status."""
    with _cycle_lock:
        row = db.execute("SELECT * FROM google_tasks_link WHERE id = 1").fetchone()
        calendar_reauth = (
            row is not None
            and row["status"] == "reauth_required"
            and row["last_error"]
            == "Google Calendar permission not granted — Reconnect"
        )
        if row is None or (
            row["status"] not in ("connected", "error") and not calendar_reauth
        ):
            return (0, 0)
        stats = CycleStats()
        calendar_stats = None
        calendar_started = False
        try:
            access_token = _refresh_access_token(db, row)
            if not row["tasklist_id"]:
                raise GoogleTasksError("Tangent Google task list is not configured")
            unfiled_list_id = str(row["tasklist_id"])
            google_lists = _GoogleLists(access_token)
            managed = ensure_lists(
                db, access_token, unfiled_list_id, stats=stats, google_lists=google_lists
            )
            folder_lists = {
                folder_id: list_id
                for list_id, folder_id in managed.items()
                if folder_id is not None
            }
            _, stale = _push(
                db, unfiled_list_id, access_token, folder_lists=folder_lists, stats=stats
            )
            _pull_all(
                db, access_token, managed,
                stats=stats, google_lists=google_lists, stale_ids=stale,
            )
            # Calendar shares this OAuth connection and five-minute tick. Keep
            # the import local to avoid a module cycle: the calendar worker
            # delegates its HTTP/parsing helpers back to this module.
            from app.services import google_calendar_worker

            calendar_started = True
            # Keep the mutable stats object even if a later Calendar phase
            # raises, so a successful push is not reported as zero.
            calendar_stats = google_calendar_worker.CalendarStats()
            google_calendar_worker.run_calendar_cycle(
                db, access_token, stats=calendar_stats
            )
            if google_calendar_worker.has_calendar_scope(row):
                db.execute(
                    """
                    UPDATE google_tasks_link SET status = 'connected', last_error = NULL,
                        last_sync_at = ?, last_pushed = ?, last_pulled = ?,
                        last_moved = ?, last_cal_pushed = ?, last_cal_pulled = ?,
                        last_cal_error = NULL
                    WHERE id = 1
                    """,
                    (
                        _now_rfc3339(), stats.pushed, stats.pulled, stats.moved,
                        calendar_stats.pushed, calendar_stats.pulled,
                    ),
                )
            else:
                # The Calendar scope gate deliberately owns status/last_error;
                # Tasks still completed and their counters must be persisted.
                db.execute(
                    """
                    UPDATE google_tasks_link SET last_sync_at = ?, last_pushed = ?,
                        last_pulled = ?, last_moved = ?, last_cal_pushed = ?,
                        last_cal_pulled = ? WHERE id = 1
                    """,
                    (
                        _now_rfc3339(), stats.pushed, stats.pulled, stats.moved,
                        calendar_stats.pushed, calendar_stats.pulled,
                    ),
                )
            db.commit()
            log.info(
                "google_tasks_worker.synced",
                pushed=stats.pushed, pulled=stats.pulled, moved=stats.moved,
            )
        except GoogleTasksError as exc:
            next_status = "reauth_required" if exc.code == "invalid_grant" else "error"
            db.execute(
                "UPDATE google_tasks_link SET status = ?, last_error = ?, "
                "last_pushed = ?, last_pulled = ?, last_moved = ? WHERE id = 1",
                (next_status, str(exc)[:500], stats.pushed, stats.pulled, stats.moved),
            )
            if calendar_started:
                db.execute(
                    "UPDATE google_tasks_link SET last_cal_pushed = ?, "
                    "last_cal_pulled = ?, last_cal_error = ? WHERE id = 1",
                    (
                        calendar_stats.pushed if calendar_stats else 0,
                        calendar_stats.pulled if calendar_stats else 0,
                        str(exc)[:500],
                    ),
                )
            db.commit()
            log.warning(
                "google_tasks_worker.sync_failed",
                status=next_status,
                error=str(exc),
            )
        return stats.pushed, stats.pulled


def run_cycle_if_connected(db: sqlite3.Connection) -> bool:
    row = db.execute(
        "SELECT status, last_error FROM google_tasks_link WHERE id = 1"
    ).fetchone()
    calendar_reauth = (
        row is not None
        and row["status"] == "reauth_required"
        and row["last_error"] == "Google Calendar permission not granted — Reconnect"
    )
    if row is None or (row["status"] != "connected" and not calendar_reauth):
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
