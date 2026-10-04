# SPDX-License-Identifier: AGPL-3.0-or-later
"""Shared custom tags: schema, migration, and the push/pull contract.

Every guarantee about what OTHER devices learn is asserted through a real
pull, not on the stored row — pull serves the recorded payload, so a DB-level
check alone would pass while the feed published something else.
"""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.sync import router as sync_router
from app.api.sync import tag_assignment_id
from app.auth import generate_token, hash_token
from app.db import init_db
from app.services.change_log import record_change

DEV_A = "device-a-11111"
DEV_B = "device-b-22222"

#: The change_log DDL as it stood before tags (v1.48.x).
PRE_TAG_CHANGE_LOG = """
CREATE TABLE change_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK (entity_type IN
        ('dump', 'notebook', 'note', 'folder', 'ink_index', 'todo',
         'calendar_event', 'ask_message')),
    entity_id TEXT NOT NULL,
    op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
    device_id TEXT NOT NULL,
    payload TEXT,
    created_at INTEGER NOT NULL
);
"""


@pytest.fixture
def authed(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    app = FastAPI()
    app.include_router(sync_router)
    return TestClient(app), token, temp_data_dir


def _db(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _push(client: TestClient, token: str, device: str, changes: list[dict]):
    res = client.post(
        "/v1/sync/push",
        json={"device_id": device, "changes": changes},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    return res.json()["results"]


def _pull(client: TestClient, token: str, device: str) -> list[dict]:
    res = client.get(
        "/v1/sync/pull",
        params={"device_id": device, "since_seq": 0},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    return res.json()["changes"]


def _tag(tag_id: str, name: str) -> dict:
    return {
        "entity_type": "tag",
        "entity_id": tag_id,
        "op": "upsert",
        "payload": {"name": name, "created_at": 10, "updated_at": 11},
    }


def _assign(tag_id: str, target_type: str, target_id: str) -> dict:
    return {
        "entity_type": "tag_assignment",
        "entity_id": tag_assignment_id(tag_id, target_type, target_id),
        "op": "upsert",
        "payload": {
            "tag_id": tag_id,
            "target_type": target_type,
            "target_id": target_id,
            "created_at": 12,
        },
    }


# --- schema + migration ----------------------------------------------------


def test_fresh_schema_has_canonical_tag_tables(tmp_path: Path):
    init_db(str(tmp_path))
    conn = _db(tmp_path)
    try:
        tables = {
            r["name"]
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        assert {"tags", "tag_assignments"} <= tables
        ddl = conn.execute(
            "SELECT sql FROM sqlite_master WHERE name='change_log'"
        ).fetchone()[0]
        assert "'tag'" in ddl and "'tag_assignment'" in ddl
        # The polymorphic target is constrained to the two taggable kinds.
        conn.execute(
            "INSERT INTO tags (id, name, created_at, updated_at) VALUES ('t', 'x', 1, 1)"
        )
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO tag_assignments (id, tag_id, target_type, target_id, "
                "created_at, updated_at) VALUES ('a', 't', 'todo', 'x', 1, 1)"
            )
        # One row per (tag, target), whatever id a buggy client sends.
        conn.execute(
            "INSERT INTO tag_assignments (id, tag_id, target_type, target_id, "
            "created_at, updated_at) VALUES ('a1', 't', 'dump', 'd', 1, 1)"
        )
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO tag_assignments (id, tag_id, target_type, target_id, "
                "created_at, updated_at) VALUES ('a2', 't', 'dump', 'd', 1, 1)"
            )
    finally:
        conn.close()


def test_pre_tag_database_migrates_preserving_the_feed_and_is_idempotent(
    tmp_path: Path,
):
    init_db(str(tmp_path))
    conn = _db(tmp_path)
    # Rewind to the pre-tag shape: old CHECK, no tag tables, real history.
    conn.executescript(
        "DROP TABLE change_log; DROP TABLE tags; DROP TABLE tag_assignments;"
        + PRE_TAG_CHANGE_LOG
    )
    for i in range(3):
        conn.execute(
            "INSERT INTO change_log (entity_type, entity_id, op, device_id, "
            "payload, created_at) VALUES ('notebook', ?, 'upsert', 'dev', '{}', 1)",
            (f"nb-{i}",),
        )
    # A deleted tail row: AUTOINCREMENT must never hand out seq 4 again.
    conn.execute(
        "INSERT INTO change_log (entity_type, entity_id, op, device_id, "
        "payload, created_at) VALUES ('notebook', 'gone', 'delete', 'dev', NULL, 1)"
    )
    conn.execute("DELETE FROM change_log WHERE entity_id = 'gone'")
    conn.commit()
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO change_log (entity_type, entity_id, op, device_id, "
            "created_at) VALUES ('tag', 't', 'delete', 'dev', 1)"
        )
    conn.rollback()
    conn.close()

    init_db(str(tmp_path))
    init_db(str(tmp_path))  # second boot: every step must be a no-op

    conn = _db(tmp_path)
    try:
        rows = conn.execute(
            "SELECT seq, entity_id FROM change_log ORDER BY seq"
        ).fetchall()
        assert [(r["seq"], r["entity_id"]) for r in rows] == [
            (1, "nb-0"),
            (2, "nb-1"),
            (3, "nb-2"),
        ]
        seq = record_change(
            conn, entity_type="tag", entity_id="t1", op="upsert",
            device_id="dev", payload={"name": "Work"},
        )
        assert seq == 5, "the AUTOINCREMENT high-water mark must survive"
        assert conn.execute("SELECT COUNT(*) FROM tags").fetchone()[0] == 0
    finally:
        conn.close()


# --- push / pull -----------------------------------------------------------


def test_tag_and_assignments_round_trip_to_another_device(authed):
    client, token, data_dir = authed
    results = _push(
        client,
        token,
        DEV_A,
        [
            _tag("tag-1", "  Deep   work "),
            _assign("tag-1", "notebook", "nb-1"),
            _assign("tag-1", "dump", "dump-1"),
        ],
    )
    assert [r["status"] for r in results] == ["applied"] * 3

    pulled = _pull(client, token, DEV_B)
    assert [(c["entity_type"], c["op"]) for c in pulled] == [
        ("tag", "upsert"),
        ("tag_assignment", "upsert"),
        ("tag_assignment", "upsert"),
    ]
    # The server republishes what it HOLDS: the normalised name.
    assert pulled[0]["payload"]["name"] == "Deep work"
    targets = {(c["payload"]["target_type"], c["payload"]["target_id"]) for c in pulled[1:]}
    assert targets == {("notebook", "nb-1"), ("dump", "dump-1")}
    assert _pull(client, token, DEV_A) == [], "the author never sees its echo"

    conn = _db(data_dir)
    try:
        assert conn.execute(
            "SELECT COUNT(*) FROM tag_assignments WHERE deleted_at IS NULL"
        ).fetchone()[0] == 2
    finally:
        conn.close()


def test_rename_publishes_the_new_name(authed):
    client, token, _ = authed
    _push(client, token, DEV_A, [_tag("tag-1", "Work")])
    _push(client, token, DEV_A, [_tag("tag-1", "Job")])
    names = [c["payload"]["name"] for c in _pull(client, token, DEV_B)]
    assert names == ["Work", "Job"]


@pytest.mark.parametrize(
    ("change", "reason"),
    [
        (_tag("tag-1", "   "), "non-empty"),
        (_tag("tag-1", "x" * 65), "longer than"),
        (
            {**_assign("tag-1", "notebook", "nb-1"), "entity_id": "ta-forged"},
            "does not match",
        ),
        (
            {
                **_assign("tag-1", "notebook", "nb-1"),
                "payload": {"tag_id": "tag-1", "target_type": "todo", "target_id": "x"},
            },
            "target_type",
        ),
        (_assign("tag-never-pushed", "dump", "d-1"), "unknown tag"),
    ],
)
def test_malformed_tag_changes_are_rejected_per_entity(authed, change, reason):
    client, token, _ = authed
    _push(client, token, DEV_A, [_tag("tag-1", "Work")])
    results = _push(client, token, DEV_A, [change, _tag("tag-2", "Fine")])
    assert results[0]["status"] == "rejected"
    assert reason in results[0]["reason"]
    assert results[1]["status"] == "applied", "one bad change spares the batch"


def test_deleting_a_tag_removes_it_from_every_notebook_and_dump(authed):
    client, token, data_dir = authed
    _push(
        client,
        token,
        DEV_A,
        [
            _tag("tag-1", "Work"),
            _tag("tag-2", "Home"),
            _assign("tag-1", "notebook", "nb-1"),
            _assign("tag-1", "dump", "dump-1"),
            _assign("tag-2", "dump", "dump-1"),
        ],
    )
    results = _push(
        client,
        token,
        DEV_A,
        [{"entity_type": "tag", "entity_id": "tag-1", "op": "delete"}],
    )
    assert results[0]["status"] == "applied"

    conn = _db(data_dir)
    try:
        live = conn.execute(
            "SELECT tag_id, target_type, target_id FROM tag_assignments "
            "WHERE deleted_at IS NULL"
        ).fetchall()
        assert [tuple(r) for r in live] == [("tag-2", "dump", "dump-1")]
        assert conn.execute(
            "SELECT deleted_at FROM tags WHERE id = 'tag-1'"
        ).fetchone()[0] is not None, "tombstoned, never removed"
    finally:
        conn.close()

    last = _pull(client, token, DEV_B)[-1]
    assert (last["entity_type"], last["entity_id"], last["op"]) == (
        "tag",
        "tag-1",
        "delete",
    )
    assert last["payload"] is None


def test_assignment_racing_a_tag_deletion_is_published_as_a_delete(authed):
    client, token, data_dir = authed
    _push(client, token, DEV_A, [_tag("tag-1", "Work")])
    _push(client, token, DEV_A, [{"entity_type": "tag", "entity_id": "tag-1", "op": "delete"}])

    # Device B tagged something offline before it pulled the deletion.
    results = _push(client, token, DEV_B, [_assign("tag-1", "dump", "dump-9")])
    assert results[0]["status"] == "applied", "B must not retry forever"

    last = _pull(client, token, DEV_A)[-1]
    assert (last["entity_type"], last["op"]) == ("tag_assignment", "delete")
    conn = _db(data_dir)
    try:
        assert conn.execute(
            "SELECT COUNT(*) FROM tag_assignments WHERE deleted_at IS NULL"
        ).fetchone()[0] == 0
    finally:
        conn.close()


def test_stale_tag_upsert_racing_a_tag_deletion_is_published_as_a_delete(authed):
    client, token, data_dir = authed
    _push(client, token, DEV_A, [_tag("tag-1", "Work"), _assign("tag-1", "dump", "dump-1")])
    _push(client, token, DEV_A, [{"entity_type": "tag", "entity_id": "tag-1", "op": "delete"}])

    # Device B renamed the tag offline before it pulled the deletion.
    results = _push(client, token, DEV_B, [_tag("tag-1", "Job")])
    assert results[0]["status"] == "applied", "B must not retry forever"

    last = _pull(client, token, DEV_A)[-1]
    assert (last["entity_type"], last["entity_id"], last["op"]) == (
        "tag",
        "tag-1",
        "delete",
    )
    assert last["payload"] is None
    conn = _db(data_dir)
    try:
        row = conn.execute(
            "SELECT name, deleted_at FROM tags WHERE id = 'tag-1'"
        ).fetchone()
        assert row["deleted_at"] is not None, "the deletion must win"
        assert row["name"] == "Work", "a stale rename must not land"
        assert conn.execute(
            "SELECT COUNT(*) FROM tag_assignments WHERE deleted_at IS NULL"
        ).fetchone()[0] == 0
    finally:
        conn.close()

    # ...and an assignment B pushes next still lands tombstoned.
    results = _push(client, token, DEV_B, [_assign("tag-1", "notebook", "nb-2")])
    assert results[0]["status"] == "applied"
    assert _pull(client, token, DEV_A)[-1]["op"] == "delete"


def test_assignment_delete_tombstones_and_a_re_add_revives_it(authed):
    client, token, data_dir = authed
    add = _assign("tag-1", "notebook", "nb-1")
    _push(client, token, DEV_A, [_tag("tag-1", "Work"), add])
    _push(
        client,
        token,
        DEV_A,
        [{"entity_type": "tag_assignment", "entity_id": add["entity_id"], "op": "delete"}],
    )
    conn = _db(data_dir)
    try:
        assert conn.execute(
            "SELECT deleted_at FROM tag_assignments WHERE id = ?", (add["entity_id"],)
        ).fetchone()[0] is not None
    finally:
        conn.close()

    _push(client, token, DEV_B, [add])
    conn = _db(data_dir)
    try:
        row = conn.execute(
            "SELECT deleted_at, COUNT(*) AS n FROM tag_assignments"
        ).fetchone()
        assert row["n"] == 1 and row["deleted_at"] is None
    finally:
        conn.close()
    ops = [(c["entity_type"], c["op"]) for c in _pull(client, token, "device-c-33333")]
    assert ops[-2:] == [("tag_assignment", "delete"), ("tag_assignment", "upsert")]


def test_assignment_id_matches_the_client_derivation():
    # The same literal is pinned in the client's tag_store_test.dart against
    # LocalDb.tagAssignmentId — the two MUST agree or every client push of
    # an assignment is rejected.
    assert (
        tag_assignment_id("tag-1", "notebook", "nb-1")
        == "ta-155235622e337c16b47339b6ff7e9ba60586247b"
    )
    assert len(tag_assignment_id("t" * 64, "notebook", "n" * 64)) == 43
