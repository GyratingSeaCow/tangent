# SPDX-License-Identifier: AGPL-3.0-or-later
"""Phase-1 server contract for synced todos."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def todo_api(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    db.execute(
        "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
        (hash_token(token), "TestUser", int(time.time())),
    )
    db.commit()
    app = FastAPI()
    app.include_router(sync_router)
    try:
        yield TestClient(app), token, db
    finally:
        db.close()


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _todo(text: str = "buy thermal paste", updated: str = "2026-09-27T12:00:00Z"):
    return {
        "text": text,
        "done_at": None,
        "due_date": "2026-09-27",
        "source": "manual",
        "source_ref": None,
        "created_at": "2026-09-27T11:00:00Z",
        "updated_at": updated,
        "deleted_at": None,
    }


def _push(client, token, changes, device="device-aaaa-1"):
    return client.post(
        "/v1/sync/push",
        json={"device_id": device, "changes": changes},
        headers=_headers(token),
    )


def test_push_stores_and_pull_fans_todo_without_opt_in(todo_api):
    client, token, db = todo_api
    response = _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-1", "op": "upsert",
        "payload": _todo(),
    }])
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "applied"
    row = db.execute("SELECT * FROM todos WHERE id = 'todo-1'").fetchone()
    assert row["text"] == "buy thermal paste"
    assert row["due_date"] == "2026-09-27"

    pulled = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()
    change = next(c for c in pulled["changes"] if c["entity_type"] == "todo")
    assert change["payload"] == {
        "id": "todo-1",
        **_todo(),
        "folder_id": None,
        "column_id": None,
        "board_order": 0,
    }


def test_todo_folder_id_round_trips(todo_api):
    client, token, db = todo_api
    payload = {**_todo(), "folder_id": "folder-shop"}
    response = _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-folder", "op": "upsert",
        "payload": payload,
    }])
    assert response.json()["results"][0]["status"] == "applied"
    assert db.execute(
        "SELECT folder_id FROM todos WHERE id = 'todo-folder'"
    ).fetchone()[0] == "folder-shop"
    pulled = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()
    change = next(c for c in pulled["changes"] if c["entity_id"] == "todo-folder")
    assert change["payload"]["folder_id"] == "folder-shop"


def test_absent_todo_folder_id_preserves_existing(todo_api):
    client, token, db = todo_api
    first = {**_todo(), "folder_id": "folder-shop"}
    _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-folder", "op": "upsert",
        "payload": first,
    }])
    narrower = _todo("renamed", "2026-09-27T12:01:00Z")
    _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-folder", "op": "upsert",
        "payload": narrower,
    }])
    assert db.execute(
        "SELECT folder_id FROM todos WHERE id = 'todo-folder'"
    ).fetchone()[0] == "folder-shop"


def test_explicit_null_todo_folder_id_clears_existing(todo_api):
    client, token, db = todo_api
    first = {**_todo(), "folder_id": "folder-shop"}
    _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-folder", "op": "upsert",
        "payload": first,
    }])
    cleared = {**_todo("renamed", "2026-09-27T12:01:00Z"), "folder_id": None}
    _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-folder", "op": "upsert",
        "payload": cleared,
    }])
    assert db.execute(
        "SELECT folder_id FROM todos WHERE id = 'todo-folder'"
    ).fetchone()[0] is None


def test_unknown_todo_folder_id_is_accepted(todo_api):
    client, token, db = todo_api
    payload = {**_todo(), "folder_id": "folder-that-does-not-exist"}
    result = _push(client, token, [{
        "entity_type": "todo", "entity_id": "todo-orphan", "op": "upsert",
        "payload": payload,
    }]).json()["results"][0]
    assert result["status"] == "applied"
    assert db.execute(
        "SELECT folder_id FROM todos WHERE id = 'todo-orphan'"
    ).fetchone()[0] == "folder-that-does-not-exist"


def test_stale_todo_update_is_dropped(todo_api):
    client, token, db = todo_api
    fresh = _todo("fresh", "2026-09-27T13:00:00Z")
    stale = _todo("stale", "2026-09-27T12:00:00Z")
    for payload in (fresh, stale):
        result = _push(client, token, [{
            "entity_type": "todo", "entity_id": "todo-stale", "op": "upsert",
            "payload": payload,
        }]).json()["results"][0]
        assert result["status"] == "applied"
    assert db.execute("SELECT text FROM todos WHERE id = 'todo-stale'").fetchone()[0] == "fresh"
    assert db.execute(
        "SELECT COUNT(*) FROM change_log WHERE entity_type='todo' AND entity_id='todo-stale'"
    ).fetchone()[0] == 1


def test_absent_nullable_keys_preserve_but_explicit_null_clears(todo_api):
    client, token, db = todo_api
    first = _todo()
    first["done_at"] = "2026-09-27T12:01:00Z"
    _push(client, token, [{"entity_type": "todo", "entity_id": "todo-null", "op": "upsert", "payload": first}])
    narrower = {
        "text": "renamed", "created_at": first["created_at"],
        "updated_at": "2026-09-27T12:02:00Z",
    }
    _push(client, token, [{"entity_type": "todo", "entity_id": "todo-null", "op": "upsert", "payload": narrower}])
    row = db.execute("SELECT done_at, due_date FROM todos WHERE id='todo-null'").fetchone()
    assert tuple(row) == ("2026-09-27T12:01:00Z", "2026-09-27")
    narrower.update(updated_at="2026-09-27T12:03:00Z", done_at=None, due_date=None)
    _push(client, token, [{"entity_type": "todo", "entity_id": "todo-null", "op": "upsert", "payload": narrower}])
    row = db.execute("SELECT done_at, due_date FROM todos WHERE id='todo-null'").fetchone()
    assert tuple(row) == (None, None)


def test_malformed_todo_rejected_without_poisoning_batch(todo_api):
    client, token, db = todo_api
    response = _push(client, token, [
        {"entity_type": "todo", "entity_id": "bad", "op": "upsert", "payload": {"text": "missing timestamps"}},
        {"entity_type": "todo", "entity_id": "good", "op": "upsert", "payload": _todo("good")},
    ])
    assert response.status_code == 200
    assert [r["status"] for r in response.json()["results"]] == ["rejected", "applied"]
    assert db.execute("SELECT id FROM todos ORDER BY id").fetchall()[0][0] == "good"


def test_soft_delete_is_stored_and_fans_out(todo_api):
    client, token, db = todo_api
    _push(client, token, [{"entity_type": "todo", "entity_id": "gone", "op": "upsert", "payload": _todo()}])
    response = _push(client, token, [{"entity_type": "todo", "entity_id": "gone", "op": "delete"}])
    assert response.json()["results"][0]["status"] == "applied"
    assert db.execute("SELECT deleted_at FROM todos WHERE id='gone'").fetchone()[0] is not None
    pulled = client.get(
        "/v1/sync/pull", params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()
    assert ("todo", "delete") in [(c["entity_type"], c["op"]) for c in pulled["changes"]]


def test_todo_folder_migration_adds_column_exactly_once(temp_data_dir):
    db_file = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_file)
    conn.execute("""
        CREATE TABLE todos (
            id TEXT PRIMARY KEY, text TEXT NOT NULL, done_at TEXT,
            due_date TEXT, source TEXT NOT NULL DEFAULT 'manual',
            source_ref TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            deleted_at TEXT
        )
    """)
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(db_file)
    columns = [row[1] for row in conn.execute("PRAGMA table_info(todos)")]
    assert columns.count("folder_id") == 1
    conn.close()


def test_todo_migration_preserves_change_log_count_max_and_exact_seqs(temp_data_dir):
    db_file = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_file)
    conn.executescript("""
        CREATE TABLE change_log (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL CHECK (entity_type IN ('dump', 'notebook', 'note', 'folder', 'ink_index')),
            entity_id TEXT NOT NULL,
            op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
            device_id TEXT NOT NULL,
            payload TEXT,
            created_at INTEGER NOT NULL
        );
        INSERT INTO change_log (seq, entity_type, entity_id, op, device_id, payload, created_at)
        VALUES (4, 'dump', 'd-1', 'upsert', 'dev-1', '{}', 1),
               (9, 'notebook', 'n-1', 'upsert', 'dev-1', '{}', 2);
    """)
    before = conn.execute("SELECT COUNT(*), MAX(seq) FROM change_log").fetchone()
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    conn = sqlite3.connect(db_file)
    after = conn.execute("SELECT COUNT(*), MAX(seq) FROM change_log").fetchone()
    assert before == after == (2, 9)
    assert conn.execute("SELECT seq FROM change_log ORDER BY seq").fetchall() == [(4,), (9,)]
    conn.execute(
        "INSERT INTO change_log (entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES ('todo', 't-1', 'upsert', 'dev-1', '{}', 3)"
    )
    assert conn.execute("SELECT MAX(seq) FROM change_log").fetchone()[0] > 9
    conn.close()


def test_google_tasks_migration_adds_server_only_todo_columns_once(temp_data_dir):
    db_file = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_file)
    conn.execute("""
        CREATE TABLE todos (
            id TEXT PRIMARY KEY, text TEXT NOT NULL, done_at TEXT,
            due_date TEXT, source TEXT NOT NULL DEFAULT 'manual', source_ref TEXT,
            folder_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            deleted_at TEXT
        )
    """)
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(db_file)
    columns = [row[1] for row in conn.execute("PRAGMA table_info(todos)")]
    assert columns.count("google_task_id") == 1
    assert columns.count("google_updated") == 1
    assert columns.count("google_tasklist_id") == 1
    folder_columns = [row[1] for row in conn.execute("PRAGMA table_info(folders)")]
    assert folder_columns.count("google_tasklist_id") == 1
    link_columns = {
        row[1] for row in conn.execute("PRAGMA table_info(google_tasks_link)")
    }
    assert {
        "client_id", "client_secret", "refresh_token", "tasklist_id",
        "oauth_state", "oauth_state_expires_at",
    }.issubset(link_columns)
    cursor_columns = {
        row[1] for row in conn.execute("PRAGMA table_info(google_list_cursor)")
    }
    assert cursor_columns == {"tasklist_id", "updated_min"}
    conn.close()


def test_google_lists_migration_moves_link_cursor_to_unfiled_list_once(temp_data_dir):
    """v1.30 rule 5: the single link cursor becomes the unfiled list's cursor,
    and already-mapped todos are recorded as living in that list. A second
    init_db (or a later worker advance) must not reset either."""
    db_file = temp_data_dir / "tangent.db"
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(db_file)
    conn.execute(
        "INSERT INTO google_tasks_link (id, tasklist_id, last_pull_updated_min, status) "
        "VALUES (1, 'list-unfiled', '2026-09-27T12:00:00.000Z', 'connected')"
    )
    conn.execute(
        "INSERT INTO todos (id, text, created_at, updated_at, google_task_id) "
        "VALUES ('mapped', 'x', '2026-09-27T11:00:00Z', '2026-09-27T11:00:00Z', 'g-1'), "
        "('unmapped', 'y', '2026-09-27T11:00:00Z', '2026-09-27T11:00:00Z', NULL)"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    conn = sqlite3.connect(db_file)
    assert conn.execute("SELECT * FROM google_list_cursor").fetchall() == [
        ("list-unfiled", "2026-09-27T12:00:00.000Z")
    ]
    assert conn.execute(
        "SELECT id, google_tasklist_id FROM todos ORDER BY id"
    ).fetchall() == [("mapped", "list-unfiled"), ("unmapped", None)]
    conn.execute(
        "UPDATE google_list_cursor SET updated_min = '2026-09-28T00:00:00.000Z'"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    conn = sqlite3.connect(db_file)
    assert conn.execute("SELECT updated_min FROM google_list_cursor").fetchone() == (
        "2026-09-28T00:00:00.000Z",
    )
    conn.close()


def test_device_upsert_preserves_google_mapping_and_omits_it_from_feed(todo_api):
    client, token, db = todo_api
    _push(client, token, [{
        "entity_type": "todo", "entity_id": "mapped", "op": "upsert",
        "payload": _todo(),
    }])
    db.execute(
        "UPDATE todos SET google_task_id = ?, google_updated = ?, google_tasklist_id = ? "
        "WHERE id = ?",
        ("google-123", "2026-09-27T12:00:01Z", "list-personal", "mapped"),
    )
    db.commit()

    result = _push(client, token, [{
        "entity_type": "todo", "entity_id": "mapped", "op": "upsert",
        "payload": _todo("device edit", "2026-09-27T12:02:00Z"),
    }]).json()["results"][0]
    assert result["status"] == "applied"
    row = db.execute(
        "SELECT google_task_id, google_updated, google_tasklist_id FROM todos "
        "WHERE id = 'mapped'"
    ).fetchone()
    assert tuple(row) == ("google-123", "2026-09-27T12:00:01Z", "list-personal")

    feed = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 1},
        headers=_headers(token),
    ).json()["changes"]
    payload = next(change["payload"] for change in feed if change["entity_id"] == "mapped")
    assert "google_task_id" not in payload
    assert "google_updated" not in payload
    assert "google_tasklist_id" not in payload


def test_device_upsert_of_folder_preserves_google_list_and_omits_it_from_feed(todo_api):
    """v1.30 Data model: folders.google_tasklist_id is server-only. A device
    re-sending the folder (rename) keeps the mapping, and the feed never
    carries it — not even when a device echoes a forged one back."""
    client, token, db = todo_api
    _push(client, token, [{
        "entity_type": "folder", "entity_id": "folder-1", "op": "upsert",
        "payload": {"name": "Personal", "created_at": 1789759637},
    }])
    db.execute(
        "UPDATE folders SET google_tasklist_id = ? WHERE id = ?",
        ("list-personal", "folder-1"),
    )
    db.commit()

    result = _push(client, token, [{
        "entity_type": "folder", "entity_id": "folder-1", "op": "upsert",
        "payload": {
            "name": "Personal stuff", "created_at": 1789759637,
            "google_tasklist_id": "forged",
        },
    }]).json()["results"][0]
    assert result["status"] == "applied"
    row = db.execute(
        "SELECT name, google_tasklist_id FROM folders WHERE id = 'folder-1'"
    ).fetchone()
    assert tuple(row) == ("Personal stuff", "list-personal")

    feed = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()["changes"]
    payloads = [c["payload"] for c in feed if c["entity_id"] == "folder-1"]
    assert len(payloads) == 2
    for payload in payloads:
        assert "google_tasklist_id" not in payload
    assert payloads[-1]["name"] == "Personal stuff"


def test_todo_board_placement_round_trips_and_absent_keys_preserve(todo_api):
    client, token, db = todo_api
    placed = {**_todo(), "column_id": "column-progress", "board_order": 7}
    assert _push(client, token, [{
        "entity_type": "todo", "entity_id": "placed", "op": "upsert",
        "payload": placed,
    }]).json()["results"][0]["status"] == "applied"

    narrower = _todo("renamed", "2026-09-27T12:01:00Z")
    assert _push(client, token, [{
        "entity_type": "todo", "entity_id": "placed", "op": "upsert",
        "payload": narrower,
    }]).json()["results"][0]["status"] == "applied"
    row = db.execute(
        "SELECT column_id, board_order FROM todos WHERE id = 'placed'"
    ).fetchone()
    assert tuple(row) == ("column-progress", 7)

    feed = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()["changes"]
    payload = [c["payload"] for c in feed if c["entity_id"] == "placed"][-1]
    assert payload["column_id"] == "column-progress"
    assert payload["board_order"] == 7


def test_todo_column_upsert_stale_write_and_soft_delete_round_trip(todo_api):
    client, token, db = todo_api
    column = {
        "name": "In review",
        "sort_order": 2,
        "created_at": "2026-09-27T11:00:00Z",
        "updated_at": "2026-09-27T12:00:00Z",
        "deleted_at": None,
    }
    first = _push(client, token, [{
        "entity_type": "todo_column", "entity_id": "column-review",
        "op": "upsert", "payload": column,
    }]).json()["results"][0]
    assert first["status"] == "applied"
    assert tuple(db.execute(
        "SELECT name, sort_order, deleted_at FROM todo_columns "
        "WHERE id = 'column-review'"
    ).fetchone()) == ("In review", 2, None)

    stale = _push(client, token, [{
        "entity_type": "todo_column", "entity_id": "column-review",
        "op": "upsert", "payload": {
            **column,
            "name": "stale name",
            "updated_at": "2026-09-27T11:59:00Z",
        },
    }]).json()["results"][0]
    assert stale["status"] == "applied"
    assert stale["seq"] == 0
    assert db.execute(
        "SELECT name FROM todo_columns WHERE id = 'column-review'"
    ).fetchone()[0] == "In review"

    deleted = _push(client, token, [{
        "entity_type": "todo_column", "entity_id": "column-review",
        "op": "upsert", "payload": {
            **column,
            "updated_at": "2026-09-27T12:01:00Z",
            "deleted_at": "2026-09-27T12:01:00Z",
        },
    }]).json()["results"][0]
    assert deleted["status"] == "applied"
    assert db.execute(
        "SELECT deleted_at FROM todo_columns WHERE id = 'column-review'"
    ).fetchone()[0] == "2026-09-27T12:01:00Z"

    feed = client.get(
        "/v1/sync/pull",
        params={"device_id": "device-bbbb-2", "since_seq": 0},
        headers=_headers(token),
    ).json()["changes"]
    changes = [c for c in feed if c["entity_type"] == "todo_column"]
    assert [c["op"] for c in changes] == ["upsert", "upsert"]
    assert changes[-1]["payload"]["deleted_at"] == "2026-09-27T12:01:00Z"


def test_todo_board_order_rejects_non_integer(todo_api):
    client, token, _ = todo_api
    response = _push(client, token, [{
        "entity_type": "todo", "entity_id": "bad-order", "op": "upsert",
        "payload": {**_todo(), "board_order": "first"},
    }])
    assert response.status_code == 200
    result = response.json()["results"][0]
    assert result["status"] == "rejected"
    assert result["reason"] == "todo board_order must be an integer"
