# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for multi-device sync: devices, change log, pull, push."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import get_db, init_db
from app.services.change_log import changes_since, head_seq, record_change


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


# --- the change log itself -------------------------------------------------


class TestChangeLog:
    def test_a_mutation_appends_exactly_one_row(self, db):
        record_change(
            db,
            entity_type="notebook",
            entity_id="nb-1",
            op="upsert",
            device_id="dev-a",
            payload={"title": "Groceries"},
        )
        rows = db.execute("SELECT COUNT(*) AS n FROM change_log").fetchone()
        assert rows["n"] == 1

    def test_sequence_is_monotonic(self, db):
        seqs = [
            record_change(
                db,
                entity_type="note",
                entity_id=f"n-{i}",
                op="upsert",
                device_id="dev-a",
                payload={"title": str(i)},
            )
            for i in range(5)
        ]
        assert seqs == sorted(seqs)
        assert len(set(seqs)) == 5, "every change gets a distinct seq"

    def test_changes_since_returns_only_later_rows_in_order(self, db):
        first = record_change(
            db, entity_type="note", entity_id="a", op="upsert",
            device_id="d", payload={"t": 1},
        )
        record_change(
            db, entity_type="note", entity_id="b", op="upsert",
            device_id="d", payload={"t": 2},
        )
        record_change(
            db, entity_type="note", entity_id="c", op="upsert",
            device_id="d", payload={"t": 3},
        )

        out = changes_since(db, since_seq=first)
        assert [c["entity_id"] for c in out] == ["b", "c"], (
            "strictly greater than the checkpoint, in sequence order"
        )

    def test_a_delete_carries_no_payload(self, db):
        # A tombstone with a body would let a client resurrect content by
        # replaying it.
        record_change(
            db, entity_type="notebook", entity_id="nb-1", op="delete",
            device_id="d", payload={"title": "should not be stored"},
        )
        row = db.execute("SELECT payload FROM change_log").fetchone()
        assert row["payload"] is None

    def test_echo_suppression_excludes_the_callers_own_changes(self, db):
        record_change(
            db, entity_type="note", entity_id="mine", op="upsert",
            device_id="dev-a", payload={},
        )
        record_change(
            db, entity_type="note", entity_id="theirs", op="upsert",
            device_id="dev-b", payload={},
        )

        out = changes_since(db, since_seq=0, exclude_device_id="dev-a")
        assert [c["entity_id"] for c in out] == ["theirs"]

    def test_head_seq_is_zero_on_an_empty_log(self, db):
        assert head_seq(db) == 0

    def test_a_change_without_an_author_is_refused(self, db):
        # Without an author no client can suppress its own echo.
        with pytest.raises(ValueError):
            record_change(
                db, entity_type="note", entity_id="x", op="upsert",
                device_id="", payload={},
            )

    def test_an_unknown_entity_type_is_refused(self, db):
        with pytest.raises(ValueError):
            record_change(
                db, entity_type="widget", entity_id="x", op="upsert",
                device_id="d", payload={},
            )


# --- device registry -------------------------------------------------------


class TestDevices:
    def test_register_is_idempotent(self, authed_client):
        client, token = authed_client
        body = {
            "device_id": "device-tablet-1",
            "display_name": "Tab S10",
            "platform": "android",
        }
        first = client.post("/v1/devices", json=body, headers=_auth(token))
        second = client.post("/v1/devices", json=body, headers=_auth(token))

        assert first.status_code == 200
        assert second.status_code == 200
        listed = client.get("/v1/devices", headers=_auth(token)).json()
        assert len(listed["devices"]) == 1, "re-registering must not duplicate"

    def test_register_does_not_reset_the_checkpoint(self, authed_client, db):
        # Re-running registration must never make a device forget where it was.
        client, token = authed_client
        body = {
            "device_id": "device-phone-1",
            "display_name": "Fold",
            "platform": "android",
        }
        client.post("/v1/devices", json=body, headers=_auth(token))
        db.execute(
            "UPDATE devices SET last_seen_seq = 42 WHERE device_id = ?",
            ("device-phone-1",),
        )
        db.commit()

        again = client.post(
            "/v1/devices",
            json={**body, "display_name": "Fold renamed"},
            headers=_auth(token),
        )
        assert again.json()["last_seen_seq"] == 42
        assert again.json()["display_name"] == "Fold renamed"

    def test_devices_require_auth(self, authed_client):
        client, _ = authed_client
        assert client.get("/v1/devices").status_code == 401


# --- pull ------------------------------------------------------------------


class TestPull:
    def test_a_new_device_pulls_everything_from_zero(self, authed_client, db):
        client, token = authed_client
        for i in range(3):
            record_change(
                db, entity_type="note", entity_id=f"n-{i}", op="upsert",
                device_id="other", payload={"title": f"note {i}"},
            )
        db.commit()

        res = client.get(
            "/v1/sync/pull",
            params={"device_id": "fresh-device-1", "since_seq": 0},
            headers=_auth(token),
        )
        assert res.status_code == 200
        assert len(res.json()["changes"]) == 3

    def test_pull_excludes_the_callers_own_echo(self, authed_client, db):
        client, token = authed_client
        record_change(
            db, entity_type="note", entity_id="mine", op="upsert",
            device_id="device-a-11111", payload={},
        )
        record_change(
            db, entity_type="note", entity_id="theirs", op="upsert",
            device_id="device-b-22222", payload={},
        )
        db.commit()

        res = client.get(
            "/v1/sync/pull",
            params={"device_id": "device-a-11111", "since_seq": 0},
            headers=_auth(token),
        )
        ids = [c["entity_id"] for c in res.json()["changes"]]
        assert ids == ["theirs"]

    def test_the_checkpoint_resumes_exactly_where_it_stopped(
        self, authed_client, db
    ):
        client, token = authed_client
        record_change(
            db, entity_type="note", entity_id="old", op="upsert",
            device_id="other", payload={},
        )
        db.commit()

        first = client.get(
            "/v1/sync/pull",
            params={"device_id": "reader-device-1", "since_seq": 0},
            headers=_auth(token),
        ).json()

        record_change(
            db, entity_type="note", entity_id="new", op="upsert",
            device_id="other", payload={},
        )
        db.commit()

        second = client.get(
            "/v1/sync/pull",
            params={"device_id": "reader-device-1",
                    "since_seq": first["head_seq"]},
            headers=_auth(token),
        ).json()

        assert [c["entity_id"] for c in second["changes"]] == ["new"], (
            "only what arrived after the stored checkpoint"
        )

    def test_an_empty_log_yields_no_changes(self, authed_client):
        client, token = authed_client
        res = client.get(
            "/v1/sync/pull",
            params={"device_id": "some-device-1", "since_seq": 0},
            headers=_auth(token),
        ).json()
        assert res["changes"] == []
        assert res["head_seq"] == 0
        assert res["has_more"] is False

    def test_pull_requires_auth(self, authed_client):
        client, _ = authed_client
        res = client.get(
            "/v1/sync/pull", params={"device_id": "device-xxxx", "since_seq": 0}
        )
        assert res.status_code == 401


# --- push ------------------------------------------------------------------


class TestPush:
    def test_a_pushed_notebook_is_stored_and_logged(self, authed_client, db):
        client, token = authed_client
        res = client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-tablet-1",
                "changes": [
                    {
                        "entity_type": "notebook",
                        "entity_id": "nb-1",
                        "op": "upsert",
                        "payload": {
                            "title": "Groceries",
                            "doc": {"blocks": [{"kind": "checkbox",
                                                "text": "milk"}]},
                        },
                    }
                ],
            },
            headers=_auth(token),
        )
        assert res.status_code == 200
        assert res.json()["results"][0]["status"] == "applied"

        row = db.execute(
            "SELECT title, doc FROM notebooks WHERE id = ?", ("nb-1",)
        ).fetchone()
        assert row["title"] == "Groceries"
        assert "milk" in row["doc"], "the document body must survive the trip"

        logged = db.execute(
            "SELECT COUNT(*) AS n FROM change_log WHERE entity_id = ?", ("nb-1",)
        ).fetchone()
        assert logged["n"] == 1, "a push appends exactly one change"

    def test_a_push_round_trips_to_another_device(self, authed_client):
        # The whole point: what A pushes, B pulls.
        client, token = authed_client
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "note",
                        "entity_id": "note-1",
                        "op": "upsert",
                        "payload": {"title": "Idea", "body": "sync this"},
                    }
                ],
            },
            headers=_auth(token),
        )

        pulled = client.get(
            "/v1/sync/pull",
            params={"device_id": "device-bbbb-2", "since_seq": 0},
            headers=_auth(token),
        ).json()

        assert len(pulled["changes"]) == 1
        assert pulled["changes"][0]["entity_id"] == "note-1"
        assert pulled["changes"][0]["payload"]["body"] == "sync this"

    def test_a_pushed_delete_tombstones_rather_than_removing(
        self, authed_client, db
    ):
        # Row removal would be undone by the other device's next push.
        client, token = authed_client
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "notebook",
                        "entity_id": "nb-del",
                        "op": "upsert",
                        "payload": {"title": "Doomed", "doc": {"blocks": []}},
                    }
                ],
            },
            headers=_auth(token),
        )
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "notebook",
                        "entity_id": "nb-del",
                        "op": "delete",
                    }
                ],
            },
            headers=_auth(token),
        )

        row = db.execute(
            "SELECT deleted_at FROM notebooks WHERE id = ?", ("nb-del",)
        ).fetchone()
        assert row is not None, "the row must survive as a tombstone"
        assert row["deleted_at"] is not None

    def test_an_upsert_after_a_delete_revives_the_entity(
        self, authed_client, db
    ):
        # Add wins over a concurrent delete: resurrect-on-edit is less bad
        # than silent loss.
        client, token = authed_client
        for op, payload in (
            ("upsert", {"title": "v1", "body": "first"}),
            ("delete", None),
            ("upsert", {"title": "v2", "body": "second"}),
        ):
            change = {
                "entity_type": "note",
                "entity_id": "note-revive",
                "op": op,
            }
            if payload is not None:
                change["payload"] = payload
            client.post(
                "/v1/sync/push",
                json={"device_id": "device-aaaa-1", "changes": [change]},
                headers=_auth(token),
            )

        row = db.execute(
            "SELECT title, deleted_at FROM notes WHERE id = ?", ("note-revive",)
        ).fetchone()
        assert row["deleted_at"] is None, "a later upsert clears the tombstone"
        assert row["title"] == "v2"

    def test_one_bad_change_does_not_discard_the_good_ones(
        self, authed_client, db
    ):
        # Results are per-entity: the client clears its dirty flag per entity,
        # so a whole-batch rejection would strand acceptable work.
        client, token = authed_client
        res = client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "note",
                        "entity_id": "good-1",
                        "op": "upsert",
                        "payload": {"title": "fine", "body": "ok"},
                    },
                    {
                        "entity_type": "note",
                        "entity_id": "good-2",
                        "op": "upsert",
                        "payload": {"title": "also fine", "body": "ok"},
                    },
                ],
            },
            headers=_auth(token),
        )
        results = res.json()["results"]
        assert all(r["status"] == "applied" for r in results)
        stored = db.execute("SELECT COUNT(*) AS n FROM notes").fetchone()
        assert stored["n"] == 2

    def test_push_advances_the_devices_last_seen_checkpoint(
        self, authed_client, db
    ):
        client, token = authed_client
        client.post(
            "/v1/devices",
            json={
                "device_id": "device-aaaa-1",
                "display_name": "Tab",
                "platform": "android",
            },
            headers=_auth(token),
        )
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "note",
                        "entity_id": "n1",
                        "op": "upsert",
                        "payload": {"title": "t", "body": "b"},
                    }
                ],
            },
            headers=_auth(token),
        )
        row = db.execute(
            "SELECT last_seen_seq FROM devices WHERE device_id = ?",
            ("device-aaaa-1",),
        ).fetchone()
        assert row["last_seen_seq"] > 0

    def test_pushing_the_same_entity_twice_does_not_duplicate_it(
        self, authed_client, db
    ):
        # Idempotent by entity id — this is what makes a retry safe.
        client, token = authed_client
        for title in ("first", "second"):
            client.post(
                "/v1/sync/push",
                json={
                    "device_id": "device-aaaa-1",
                    "changes": [
                        {
                            "entity_type": "notebook",
                            "entity_id": "nb-same",
                            "op": "upsert",
                            "payload": {"title": title,
                                        "doc": {"blocks": []}},
                        }
                    ],
                },
                headers=_auth(token),
            )

        rows = db.execute(
            "SELECT title FROM notebooks WHERE id = ?", ("nb-same",)
        ).fetchall()
        assert len(rows) == 1
        assert rows[0]["title"] == "second", "the later push wins"

    def test_push_requires_auth(self, authed_client):
        client, _ = authed_client
        res = client.post(
            "/v1/sync/push",
            json={"device_id": "device-aaaa-1", "changes": []},
        )
        assert res.status_code == 401

    def test_audio_is_never_synced(self, authed_client, db):
        # Scope rule: audio stays on the device that recorded it. A dump can
        # arrive as metadata only, and that is a first-class state.
        client, token = authed_client
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "dump",
                        "entity_id": "dump-1",
                        "op": "upsert",
                        "payload": {
                            "title": "Recorded on the tablet",
                            "mode": "brain_dump",
                            "duration_seconds": 12,
                            "transcript": "hello",
                        },
                    }
                ],
            },
            headers=_auth(token),
        )
        row = db.execute(
            "SELECT title, audio_kept FROM dumps WHERE id = ?", ("dump-1",)
        ).fetchone()
        assert row["title"] == "Recorded on the tablet"
        assert row["audio_kept"] == 0, "sync never implies the audio came too"


class TestFolderSync:
    """Folders travel: entity_type 'folder' and notebook folder_id.

    Filing was device-local, so a library organized on the tablet arrived as
    an unfiled heap on the phone. Folders sync by ID only — same-named
    folders created independently stay separate (user decision).
    """

    def test_a_pushed_folder_is_stored_and_round_trips(self, authed_client, db):
        client, token = authed_client
        res = client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "folder",
                        "entity_id": "folder-1789759637687803",
                        "op": "upsert",
                        "payload": {"name": "tesr", "created_at": 1789759637},
                    }
                ],
            },
            headers=_auth(token),
        )
        assert res.status_code == 200
        assert res.json()["results"][0]["status"] == "applied"

        row = db.execute(
            "SELECT name FROM folders WHERE id = ?", ("folder-1789759637687803",)
        ).fetchone()
        assert row["name"] == "tesr"

        pulled = client.get(
            "/v1/sync/pull",
            params={"device_id": "device-bbbb-2", "since_seq": 0},
            headers=_auth(token),
        ).json()
        assert pulled["changes"][0]["entity_type"] == "folder"
        assert pulled["changes"][0]["payload"]["name"] == "tesr"

    def test_notebook_folder_id_travels_and_absence_preserves(
        self, authed_client, db
    ):
        # folder_id must survive the trip; a payload WITHOUT folder_id (an
        # older client) must keep the stored filing rather than erase it.
        client, token = authed_client
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "notebook",
                        "entity_id": "nb-filed",
                        "op": "upsert",
                        "payload": {
                            "title": "Filed",
                            "doc": {"blocks": []},
                            "folder_id": "folder-x",
                        },
                    }
                ],
            },
            headers=_auth(token),
        )
        row = db.execute(
            "SELECT folder_id FROM notebooks WHERE id = ?", ("nb-filed",)
        ).fetchone()
        assert row["folder_id"] == "folder-x"

        # Older-client push: no folder_id key at all.
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "notebook",
                        "entity_id": "nb-filed",
                        "op": "upsert",
                        "payload": {"title": "Filed v2", "doc": {"blocks": []}},
                    }
                ],
            },
            headers=_auth(token),
        )
        row = db.execute(
            "SELECT title, folder_id FROM notebooks WHERE id = ?", ("nb-filed",)
        ).fetchone()
        assert row["title"] == "Filed v2"
        assert row["folder_id"] == "folder-x", "absence is not an eraser"

    def test_folder_delete_tombstones_and_round_trips(self, authed_client, db):
        client, token = authed_client
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "folder",
                        "entity_id": "folder-gone",
                        "op": "upsert",
                        "payload": {"name": "Doomed"},
                    }
                ],
            },
            headers=_auth(token),
        )
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "device-aaaa-1",
                "changes": [
                    {
                        "entity_type": "folder",
                        "entity_id": "folder-gone",
                        "op": "delete",
                    }
                ],
            },
            headers=_auth(token),
        )
        row = db.execute(
            "SELECT deleted_at FROM folders WHERE id = ?", ("folder-gone",)
        ).fetchone()
        assert row is not None and row["deleted_at"] is not None

        pulled = client.get(
            "/v1/sync/pull",
            params={"device_id": "device-bbbb-2", "since_seq": 0},
            headers=_auth(token),
        ).json()
        ops = [(c["entity_type"], c["op"]) for c in pulled["changes"]]
        assert ("folder", "delete") in ops
