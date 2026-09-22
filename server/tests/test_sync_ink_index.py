# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the ink_index sync entity (Task 3).

The load-bearing discovery pinned here: the client pushes 'doc' and 'ink' as
SEPARATE payload fields, and historically only 'doc' was stored — ink lived
solely in change_log payloads. These tests push ink through the REAL sync
path and assert the worker can see the strokes, plus the migration that
backfills notebooks.ink from the newest change_log payload carrying ink.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import ocr_worker


@pytest.fixture(autouse=True)
def _reset_worker():
    ocr_worker._reset_for_tests()
    yield
    ocr_worker._reset_for_tests()


@pytest.fixture
def authed_client(temp_data_dir: Path):
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

    from app.api.sync import router as sync_router

    app = FastAPI()
    app.include_router(sync_router)
    return TestClient(app), token


@pytest.fixture
def db(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _stroke(sid: str, x0: float, y0: float, w: float = 30.0, h: float = 20.0) -> dict:
    return {
        "id": sid,
        "width": 3,
        "tool": "pen",
        "points": [
            {"x": x0, "y": y0},
            {"x": x0 + w / 2, "y": y0 + h},
            {"x": x0 + w, "y": y0 + h / 2},
        ],
    }


#: One line, two words (50px x-gap > 0.6 * 20px median height).
STROKES = [_stroke("s-a", 0, 0), _stroke("s-b", 80, 0)]


def _push_notebook(client, token, nb_id="nb-ink", ink=True, title="Ink", op="upsert"):
    change: dict = {"entity_type": "notebook", "entity_id": nb_id, "op": op}
    if op == "upsert":
        payload: dict = {"title": title, "doc": {"blocks": []}, "created_at": 1}
        if ink:
            payload["ink"] = {"strokes": STROKES}
        change["payload"] = payload
    return client.post(
        "/v1/sync/push",
        json={"device_id": "device-aaaa-1", "changes": [change]},
        headers=_auth(token),
    )


# ---------------------------------------------------------------------------
# push side: ink must actually reach the worker
# ---------------------------------------------------------------------------


class TestPushStoresInk:
    def test_pushed_ink_is_stored_and_the_worker_sees_the_strokes(
        self, authed_client, db
    ):
        # THE pin for the architecture discovery: doc and ink are separate
        # payload fields, and notebooks.doc never carries strokes. The whole
        # feature is dead if this regresses.
        client, token = authed_client
        res = _push_notebook(client, token)
        assert res.json()["results"][0]["status"] == "applied"

        row = db.execute(
            "SELECT doc, ink FROM notebooks WHERE id = 'nb-ink'"
        ).fetchone()
        stored = json.loads(row["ink"])
        assert [s["id"] for s in stored["strokes"]] == ["s-a", "s-b"]

        # End-to-end: the worker indexes what the sync push delivered.
        ocr_worker.reindex_notebook(
            db, "nb-ink", infer=lambda img: "hello world", now=100
        )
        rows = db.execute(
            "SELECT word_text FROM ink_index WHERE notebook_id = 'nb-ink' ORDER BY id"
        ).fetchall()
        assert [r["word_text"] for r in rows] == ["hello", "world"]

    def test_a_payload_without_ink_preserves_stored_ink(self, authed_client, db):
        # An older client (or a title-only edit) omits ink entirely —
        # absence is not an eraser, same rule as folder_id.
        client, token = authed_client
        _push_notebook(client, token)
        _push_notebook(client, token, ink=False, title="Renamed")

        row = db.execute(
            "SELECT title, ink FROM notebooks WHERE id = 'nb-ink'"
        ).fetchone()
        assert row["title"] == "Renamed"
        assert row["ink"] is not None, "absence is not an eraser"
        assert [s["id"] for s in json.loads(row["ink"])["strokes"]] == ["s-a", "s-b"]

    def test_notebook_push_enqueues_a_reindex(self, authed_client):
        client, token = authed_client
        _push_notebook(client, token)
        assert "nb-ink" in ocr_worker.pending()

    def test_notebook_delete_push_also_enqueues(self, authed_client):
        client, token = authed_client
        _push_notebook(client, token)
        ocr_worker._reset_for_tests()
        _push_notebook(client, token, op="delete")
        assert "nb-ink" in ocr_worker.pending()

    def test_clients_cannot_push_ink_index_rows(self, authed_client, db):
        # The index is server-generated; a client push of it is rejected
        # per-entity, not a 4xx for the whole batch.
        client, token = authed_client
        res = client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "ink_index",
                        "entity_id": "nb-ink",
                        "op": "upsert",
                        "payload": {"rows": []},
                    }
                ],
            },
            headers=_auth(token),
        )
        assert res.status_code == 200
        assert res.json()["results"][0]["status"] == "rejected"
        count = db.execute("SELECT COUNT(*) AS n FROM ink_index").fetchone()["n"]
        assert count == 0


# ---------------------------------------------------------------------------
# pull side: replace-set semantics, additive for old clients
# ---------------------------------------------------------------------------


class TestPullInkIndex:
    def _push_and_index(self, client, token, db):
        _push_notebook(client, token)
        ocr_worker.reindex_notebook(
            db, "nb-ink", infer=lambda img: "hello world", now=100
        )

    def test_pull_returns_the_full_replace_set_for_the_notebook(
        self, authed_client, db
    ):
        client, token = authed_client
        self._push_and_index(client, token, db)

        pulled = client.get(
            "/v1/sync/pull",
            params={
                "device_id": "device-bbbb-2",
                "since_seq": 0,
                "include_ink_index": True,
            },
            headers=_auth(token),
        ).json()

        kinds = [(c["entity_type"], c["op"]) for c in pulled["changes"]]
        assert ("notebook", "upsert") in kinds
        assert ("ink_index", "upsert") in kinds

        ink_change = next(
            c for c in pulled["changes"] if c["entity_type"] == "ink_index"
        )
        payload = ink_change["payload"]
        assert payload["notebook_id"] == "nb-ink"
        rows = payload["rows"]
        assert [r["word_text"] for r in rows] == ["hello", "world"]
        assert rows[0]["stroke_ids"] == ["s-a"]
        assert rows[0]["bbox"] == pytest.approx([0.0, 0.0, 30.0, 20.0])
        assert {"id", "line_id", "word_text", "bbox", "stroke_ids", "model",
                "indexed_at"} <= set(rows[0])

    def test_replace_set_reflects_current_rows_not_the_moment_of_logging(
        self, authed_client, db
    ):
        # The payload is built AT PULL TIME from the live table: a client that
        # pulls late gets the current index, and replace-set semantics mean
        # duplicated log entries are harmless.
        client, token = authed_client
        self._push_and_index(client, token, db)
        db.execute(
            "UPDATE ink_index SET word_text = 'edited' WHERE word_text = 'hello'"
        )
        db.commit()

        pulled = client.get(
            "/v1/sync/pull",
            params={
                "device_id": "device-bbbb-2",
                "since_seq": 0,
                "include_ink_index": True,
            },
            headers=_auth(token),
        ).json()
        ink_change = next(
            c for c in pulled["changes"] if c["entity_type"] == "ink_index"
        )
        assert [r["word_text"] for r in ink_change["payload"]["rows"]] == [
            "edited",
            "world",
        ]

    def test_a_legacy_client_never_sees_ink_index_changes(self, authed_client, db):
        # Old apps neither send the flag nor know the entity. They must get
        # everything else — and a checkpoint that clears the filtered rows,
        # or they would re-pull forever.
        client, token = authed_client
        self._push_and_index(client, token, db)

        pulled = client.get(
            "/v1/sync/pull",
            params={"device_id": "device-bbbb-2", "since_seq": 0},
            headers=_auth(token),
        ).json()

        types = {c["entity_type"] for c in pulled["changes"]}
        assert "ink_index" not in types
        assert "notebook" in types

        with_flag = client.get(
            "/v1/sync/pull",
            params={
                "device_id": "device-bbbb-2",
                "since_seq": 0,
                "include_ink_index": True,
            },
            headers=_auth(token),
        ).json()
        assert pulled["head_seq"] == with_flag["head_seq"], (
            "filtering must not stall the legacy client's checkpoint"
        )

    def test_deleted_notebook_round_trips_an_ink_index_delete(
        self, authed_client, db
    ):
        client, token = authed_client
        self._push_and_index(client, token, db)
        _push_notebook(client, token, op="delete")
        ocr_worker.reindex_notebook(db, "nb-ink", infer=lambda img: "x", now=200)

        pulled = client.get(
            "/v1/sync/pull",
            params={
                "device_id": "device-bbbb-2",
                "since_seq": 0,
                "include_ink_index": True,
            },
            headers=_auth(token),
        ).json()
        kinds = [(c["entity_type"], c["op"]) for c in pulled["changes"]]
        assert ("ink_index", "delete") in kinds


# ---------------------------------------------------------------------------
# schema + migration
# ---------------------------------------------------------------------------


class TestSchema:
    def test_fresh_schema_has_ink_column_index_table_and_check(self, db):
        cols = {r[1] for r in db.execute("PRAGMA table_info(notebooks)")}
        assert "ink" in cols

        tables = {
            r[0]
            for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        assert "ink_index" in tables
        indexes = {r[1] for r in db.execute("PRAGMA index_list('ink_index')")}
        assert {"idx_ink_index_notebook", "idx_ink_index_word_lower"} <= indexes

        # change_log CHECK admits the new entity.
        db.execute(
            "INSERT INTO change_log "
            "(entity_type, entity_id, op, device_id, payload, created_at) "
            "VALUES ('ink_index', 'nb-1', 'upsert', 'server', NULL, 1)"
        )

    def test_migration_backfills_ink_from_the_newest_payload_carrying_ink(
        self, temp_data_dir
    ):
        # A production DB: notebooks without an ink column, ink only inside
        # change_log payloads. The NEWEST payload CARRYING ink wins — a later
        # title-only upsert (no ink key) must not blank the strokes.
        db_file = temp_data_dir / "tangent.db"
        conn = sqlite3.connect(db_file)
        conn.executescript(
            """
            CREATE TABLE notebooks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                doc TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                deleted_at INTEGER,
                origin_device_id TEXT,
                folder_id TEXT
            );
            CREATE TABLE change_log (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                entity_type TEXT NOT NULL
                    CHECK (entity_type IN ('dump', 'notebook', 'note', 'folder')),
                entity_id TEXT NOT NULL,
                op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
                device_id TEXT NOT NULL,
                payload TEXT,
                created_at INTEGER NOT NULL
            );
            INSERT INTO notebooks (id, title, doc, created_at, updated_at)
            VALUES ('nb-old', 'Legacy', '{}', 1, 1);
            """
        )
        old = json.dumps({"title": "Legacy", "ink": {"strokes": [{"id": "stale"}]}})
        new = json.dumps({"title": "Legacy", "ink": {"strokes": [{"id": "fresh"}]}})
        title_only = json.dumps({"title": "Renamed"})
        conn.executemany(
            "INSERT INTO change_log "
            "(entity_type, entity_id, op, device_id, payload, created_at) "
            "VALUES ('notebook', 'nb-old', 'upsert', 'dev-1', ?, ?)",
            [(old, 100), (new, 101), (title_only, 102)],
        )
        conn.commit()
        conn.close()

        init_db(str(temp_data_dir))
        init_db(str(temp_data_dir))  # idempotent

        conn = sqlite3.connect(db_file)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute(
                "SELECT ink FROM notebooks WHERE id = 'nb-old'"
            ).fetchone()
            ink = json.loads(row["ink"])
            assert [s["id"] for s in ink["strokes"]] == ["fresh"], (
                "newest payload CARRYING ink wins; a title-only echo is not an eraser"
            )
            seqs = [
                r["seq"]
                for r in conn.execute("SELECT seq FROM change_log ORDER BY seq")
            ]
            assert seqs == [1, 2, 3], "device checkpoints point into these seqs"
            conn.execute(
                "INSERT INTO change_log "
                "(entity_type, entity_id, op, device_id, payload, created_at) "
                "VALUES ('ink_index', 'nb-old', 'upsert', 'server', NULL, 103)"
            )
        finally:
            conn.close()

    def test_migration_stores_string_ink_payload_single_encoded(
        self, temp_data_dir
    ):
        # THE production bug: the client pushes ink as JSON TEXT inside the
        # payload. The backfill must store it as-is (single-encoded), not
        # json.dumps it again — double-encoding made json.loads(ink) yield a
        # str and the OCR worker silently indexed nothing, 25/25 notebooks.
        from app.db import _migrate_notebooks_ink

        init_db(str(temp_data_dir))
        conn = sqlite3.connect(temp_data_dir / "tangent.db")
        try:
            conn.execute(
                "INSERT INTO notebooks (id, title, doc, created_at, updated_at) "
                "VALUES ('nb-str', 'S', '{}', 1, 1)"
            )
            payload = json.dumps(
                {
                    "title": "S",
                    "ink": json.dumps({"strokes": [{"id": "s-1"}]}),
                }
            )
            conn.execute(
                "INSERT INTO change_log "
                "(entity_type, entity_id, op, device_id, payload, created_at) "
                "VALUES ('notebook', 'nb-str', 'upsert', 'dev-1', ?, 100)",
                (payload,),
            )
            conn.commit()

            _migrate_notebooks_ink(conn)

            row = conn.execute(
                "SELECT ink FROM notebooks WHERE id = 'nb-str'"
            ).fetchone()
            ink = json.loads(row[0])
            assert isinstance(ink, dict), (
                "string ink payload must land single-encoded"
            )
            assert [s["id"] for s in ink["strokes"]] == ["s-1"]
        finally:
            conn.close()


class TestNormalizeDoubleEncodedInk:
    """Boot repair for rows the buggy backfill already double-encoded."""

    def _seed_ink(self, temp_data_dir, nb_id: str, ink_text: str) -> None:
        conn = sqlite3.connect(temp_data_dir / "tangent.db")
        try:
            conn.execute(
                "INSERT INTO notebooks (id, title, doc, ink, created_at, "
                "updated_at) VALUES (?, 'T', '{}', ?, 1, 1)",
                (nb_id, ink_text),
            )
            conn.commit()
        finally:
            conn.close()

    def _read_ink(self, temp_data_dir, nb_id: str) -> str:
        conn = sqlite3.connect(temp_data_dir / "tangent.db")
        try:
            return conn.execute(
                "SELECT ink FROM notebooks WHERE id = ?", (nb_id,)
            ).fetchone()[0]
        finally:
            conn.close()

    def test_boot_fixes_double_encoded_row_in_place(self, temp_data_dir):
        init_db(str(temp_data_dir))
        inner = json.dumps({"strokes": [{"id": "s-2"}]})
        self._seed_ink(temp_data_dir, "nb-dbl", json.dumps(inner))

        init_db(str(temp_data_dir))  # boot normalization runs here

        ink = json.loads(self._read_ink(temp_data_dir, "nb-dbl"))
        assert isinstance(ink, dict), "double-encoded row repaired in place"
        assert [s["id"] for s in ink["strokes"]] == ["s-2"]

        init_db(str(temp_data_dir))  # idempotent: second boot is a no-op
        assert json.loads(self._read_ink(temp_data_dir, "nb-dbl")) == ink

    def test_boot_unwraps_many_layers(self, temp_data_dir):
        init_db(str(temp_data_dir))
        value = json.dumps({"strokes": []})
        for _ in range(4):  # 4 wrapper layers, general N-layer case
            value = json.dumps(value)
        self._seed_ink(temp_data_dir, "nb-deep", value)

        init_db(str(temp_data_dir))

        assert json.loads(self._read_ink(temp_data_dir, "nb-deep")) == {
            "strokes": []
        }

    def test_boot_leaves_truly_bad_ink_untouched(self, temp_data_dir):
        init_db(str(temp_data_dir))
        # Decodes to a str that is not JSON — can never resolve to a dict.
        bad = json.dumps("this is not ink")
        self._seed_ink(temp_data_dir, "nb-bad", bad)

        init_db(str(temp_data_dir))  # must not crash and must not mangle

        assert self._read_ink(temp_data_dir, "nb-bad") == bad
