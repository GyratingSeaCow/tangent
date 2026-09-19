# SPDX-License-Identifier: AGPL-3.0-or-later
"""Recording (dump) changes must reach the sync change feed.

Jeff's defect report: only notebooks sync. Root cause: the ordinary dump
routes (create, patch, delete, audio upload) and the transcription job
completion path never call record_change, so recordings simply never enter
the feed that /v1/sync/pull serves.

These tests pin the repair: every mutation of a dump on the server publishes
a change, attributed to the originating device when the caller says who it
is (X-Device-Id), so pull's echo suppression keeps working.
"""

import io
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import init_db


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
    app.include_router(dumps_router)
    app.include_router(sync_router)
    return TestClient(app), token, temp_data_dir


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _feed(data_dir: Path) -> list[sqlite3.Row]:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(
            "SELECT * FROM change_log ORDER BY seq"
        ).fetchall()
    finally:
        conn.close()


def _create(client, token, dump_id="dump-0001", title="Morning thoughts"):
    resp = client.post(
        "/v1/dumps",
        json={
            "id": dump_id,
            "mode": "brain_dump",
            "duration_seconds": 12,
            "title": title,
            "created_at": "2026-09-18T12:00:00Z",
        },
        headers={**_auth(token), "X-Device-Id": "dev-tablet"},
    )
    assert resp.status_code == 201, resp.text
    return resp


class TestDumpMutationsPublishChanges:
    def test_create_dump_publishes_upsert(self, authed_client):
        client, token, data_dir = authed_client
        _create(client, token)

        feed = _feed(data_dir)
        assert len(feed) == 1
        row = feed[0]
        assert row["entity_type"] == "dump"
        assert row["entity_id"] == "dump-0001"
        assert row["op"] == "upsert"
        assert row["device_id"] == "dev-tablet"
        assert '"Morning thoughts"' in row["payload"]

    def test_create_without_device_header_attributes_to_server(
        self, authed_client
    ):
        client, token, data_dir = authed_client
        resp = client.post(
            "/v1/dumps",
            json={
                "id": "dump-0002",
                "mode": "brain_dump",
                "duration_seconds": 3,
                "title": "No header",
                "created_at": "2026-09-18T12:00:00Z",
            },
            headers=_auth(token),
        )
        assert resp.status_code == 201
        assert _feed(data_dir)[0]["device_id"] == "server"

    def test_patch_dump_publishes_upsert_with_new_title(self, authed_client):
        client, token, data_dir = authed_client
        _create(client, token)

        resp = client.patch(
            "/v1/dumps/dump-0001",
            json={"title": "Renamed"},
            headers={**_auth(token), "X-Device-Id": "dev-fold"},
        )
        assert resp.status_code == 200, resp.text

        feed = _feed(data_dir)
        assert len(feed) == 2
        assert feed[-1]["op"] == "upsert"
        assert feed[-1]["device_id"] == "dev-fold"
        assert '"Renamed"' in feed[-1]["payload"]

    def test_delete_dump_publishes_tombstone(self, authed_client):
        client, token, data_dir = authed_client
        _create(client, token)

        resp = client.delete(
            "/v1/dumps/dump-0001",
            headers={**_auth(token), "X-Device-Id": "dev-tablet"},
        )
        assert resp.status_code == 204

        feed = _feed(data_dir)
        assert feed[-1]["op"] == "delete"
        assert feed[-1]["entity_id"] == "dump-0001"
        # A tombstone carries no body: nothing to resurrect from.
        assert feed[-1]["payload"] is None

    def test_audio_upload_publishes_availability(self, authed_client):
        client, token, data_dir = authed_client
        _create(client, token)

        resp = client.post(
            "/v1/dumps/dump-0001/audio",
            files={"audio": ("dump-0001.opus", io.BytesIO(b"OggS fake"), "audio/ogg")},
            headers={**_auth(token), "X-Device-Id": "dev-tablet"},
        )
        assert resp.status_code == 204, resp.text

        feed = _feed(data_dir)
        assert feed[-1]["op"] == "upsert"
        assert '"audio_kept": true' in feed[-1]["payload"]

    def test_own_changes_are_excluded_from_pull(self, authed_client):
        """The whole point of attribution: no echo."""
        client, token, data_dir = authed_client
        _create(client, token)  # attributed to dev-tablet

        # Register both devices so pull is legal.
        for dev in ("dev-tablet", "dev-fold"):
            client.post(
                "/v1/devices",
                json={"device_id": dev, "display_name": dev},
                headers=_auth(token),
            )

        own = client.get(
            "/v1/sync/pull",
            params={"device_id": "dev-tablet", "since": 0},
            headers=_auth(token),
        ).json()
        other = client.get(
            "/v1/sync/pull",
            params={"device_id": "dev-fold", "since": 0},
            headers=_auth(token),
        ).json()

        assert [c["entity_id"] for c in own["changes"]] == []
        assert [c["entity_id"] for c in other["changes"]] == ["dump-0001"]


class TestApplyDumpPreservesServerState:
    def test_apply_dump_does_not_reset_audio_kept(self, authed_client):
        """A metadata push from a device that never held the audio must not
        make the server forget it HAS the audio."""
        client, token, data_dir = authed_client
        _create(client, token)
        client.post(
            "/v1/dumps/dump-0001/audio",
            files={"audio": ("dump-0001.opus", io.BytesIO(b"OggS fake"), "audio/ogg")},
            headers=_auth(token),
        )

        client.post(
            "/v1/devices",
            json={"device_id": "dev-fold", "display_name": "Fold"},
            headers=_auth(token),
        )
        resp = client.post(
            "/v1/sync/push",
            json={
                "device_id": "dev-fold",
                "changes": [
                    {
                        "entity_type": "dump",
                        "entity_id": "dump-0001",
                        "op": "upsert",
                        "payload": {"title": "Fold renamed this"},
                        "updated_at": int(time.time()),
                    }
                ],
            },
            headers=_auth(token),
        )
        assert resp.status_code == 200, resp.text

        conn = sqlite3.connect(data_dir / "tangent.db")
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute(
                "SELECT title, audio_kept FROM dumps WHERE id = 'dump-0001'"
            ).fetchone()
        finally:
            conn.close()
        assert row["title"] == "Fold renamed this"
        assert row["audio_kept"] == 1

    def test_push_republishes_server_truth_not_client_payload(
        self, authed_client
    ):
        """The FEED must carry what the server holds, not what the device sent.

        The DB keeping audio_kept=1 is not enough: pull serves the recorded
        payload, so if that payload echoes the sending device's omission,
        every other device is told the audio is unavailable while the file
        sits on disk. Only an end-to-end pull catches this.
        """
        client, token, _ = authed_client
        _create(client, token)
        client.post(
            "/v1/dumps/dump-0001/audio",
            files={"audio": ("dump-0001.opus", io.BytesIO(b"OggS fake"), "audio/ogg")},
            headers=_auth(token),
        )
        for dev in ("dev-fold", "dev-tablet"):
            client.post(
                "/v1/devices",
                json={"device_id": dev, "display_name": dev},
                headers=_auth(token),
            )

        # The Fold holds no audio, so its push omits audio_kept entirely.
        client.post(
            "/v1/sync/push",
            json={
                "device_id": "dev-fold",
                "changes": [
                    {
                        "entity_type": "dump",
                        "entity_id": "dump-0001",
                        "op": "upsert",
                        "payload": {"title": "Fold renamed this"},
                        "updated_at": int(time.time()),
                    }
                ],
            },
            headers=_auth(token),
        )

        page = client.get(
            "/v1/sync/pull",
            params={"device_id": "dev-tablet", "since_seq": 0},
            headers=_auth(token),
        ).json()
        latest = [
            c
            for c in page["changes"]
            if c["entity_id"] == "dump-0001" and c["op"] == "upsert"
        ][-1]
        assert latest["payload"]["title"] == "Fold renamed this"
        assert latest["payload"]["audio_kept"] is True, (
            "the feed told other devices the audio is gone while the server "
            "still has the file"
        )

    def test_apply_dump_stores_meeting_notes(self, authed_client):
        client, token, data_dir = authed_client
        client.post(
            "/v1/devices",
            json={"device_id": "dev-fold", "display_name": "Fold"},
            headers=_auth(token),
        )
        resp = client.post(
            "/v1/sync/push",
            json={
                "device_id": "dev-fold",
                "changes": [
                    {
                        "entity_type": "dump",
                        "entity_id": "dump-0009",
                        "op": "upsert",
                        "payload": {
                            "title": "Standup",
                            "mode": "meeting",
                            "meeting_notes": "action: ship it",
                            "created_at": int(time.time()),
                        },
                        "updated_at": int(time.time()),
                    }
                ],
            },
            headers=_auth(token),
        )
        assert resp.status_code == 200, resp.text

        conn = sqlite3.connect(data_dir / "tangent.db")
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute(
                "SELECT meeting_notes, mode FROM dumps WHERE id = 'dump-0009'"
            ).fetchone()
        finally:
            conn.close()
        assert row["mode"] == "meeting"
        assert row["meeting_notes"] == "action: ship it"
