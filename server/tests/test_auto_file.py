# SPDX-License-Identifier: AGPL-3.0-or-later
"""Auto-file (spec 2026-09-30, queued item #3): after transcription the
server picks the best matching EXISTING folder. Confident -> the dump is
filed and the change is announced to sync; unsure -> nothing happens, no
notification. A device pushing its own filing (Undo included) retires the
server's auto-file markers."""

from __future__ import annotations

import json
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
from app.services import auto_file
from app.services.job_queue import run_job_inline
from app.services.transcription import TranscriptionResult

WOOD_TRANSCRIPT = (
    "Measured the walnut boards and cut the dovetails on the table saw, "
    "then sanded the tabletop smooth before the glue up. The chisel needs "
    "sharpening before the next joinery session in the workshop."
)

COOKING_TEXTS = [
    "Roasted the chicken thighs with garlic butter and thyme in the oven.",
    "Simmered the tomato sauce and tasted the seasoning for the pasta recipe.",
]

WOODWORKING_TEXTS = [
    "Cut the walnut board on the table saw and cleaned up the dovetails "
    "with a chisel before sanding.",
    "Glued up the tabletop panels and flattened them with the hand plane "
    "in the workshop.",
]


def _connect(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _seed_folder(conn: sqlite3.Connection, folder_id: str, name: str) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO folders (id, name, created_at, updated_at) "
        "VALUES (?, ?, ?, ?)",
        (folder_id, name, now, now),
    )


def _seed_dump(
    conn: sqlite3.Connection,
    dump_id: str,
    *,
    title: str = "Capture",
    transcript: str | None = None,
    folder_id: str | None = None,
    mode: str = "brain_dump",
) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, "
        "transcript, folder_id, created_at, updated_at, audio_kept) "
        "VALUES (?, 'single-user', ?, 10, ?, ?, ?, ?, ?, 0)",
        (dump_id, mode, title, transcript, folder_id, now, now),
    )


def _two_folder_corpus(conn: sqlite3.Connection) -> None:
    """Woodworking and Cooking folders, each holding on-topic captures."""
    _seed_folder(conn, "folder-wood", "Woodworking")
    _seed_folder(conn, "folder-cook", "Cooking")
    for index, text in enumerate(WOODWORKING_TEXTS):
        _seed_dump(
            conn,
            f"dump-wood-{index}",
            title="Shop notes",
            transcript=text,
            folder_id="folder-wood",
        )
    for index, text in enumerate(COOKING_TEXTS):
        _seed_dump(
            conn,
            f"dump-cook-{index}",
            title="Kitchen notes",
            transcript=text,
            folder_id="folder-cook",
        )
    conn.commit()


class TestClassify:
    def test_confident_transcript_picks_the_matching_folder(
        self, temp_data_dir
    ):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            verdict = auto_file.classify(
                WOOD_TRANSCRIPT, auto_file.folder_profiles(conn)
            )
        finally:
            conn.close()
        assert verdict is not None
        folder_id, score = verdict
        assert folder_id == "folder-wood"
        assert score >= auto_file.ACCEPT

    def test_unrelated_transcript_is_unsure(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            verdict = auto_file.classify(
                "Quarterly budget review meeting about headcount and hiring "
                "plans for the finance team next year.",
                auto_file.folder_profiles(conn),
            )
        finally:
            conn.close()
        assert verdict is None

    def test_transcript_matching_both_folders_is_unsure(self, temp_data_dir):
        """A capture both folders plausibly fit fails the MARGIN gate."""
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            verdict = auto_file.classify(
                "Cut the walnut board with the table saw then simmered the "
                "tomato sauce for the pasta recipe.",
                auto_file.folder_profiles(conn),
            )
        finally:
            conn.close()
        assert verdict is None

    def test_no_folders_means_no_verdict(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            verdict = auto_file.classify(
                WOOD_TRANSCRIPT, auto_file.folder_profiles(conn)
            )
        finally:
            conn.close()
        assert verdict is None

    def test_empty_transcript_means_no_verdict(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            verdict = auto_file.classify("", auto_file.folder_profiles(conn))
        finally:
            conn.close()
        assert verdict is None

    def test_one_shared_word_is_not_confidence(self, temp_data_dir):
        """MIN_SHARED_TERMS: a single coincidental word must never file."""
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            verdict = auto_file.classify(
                "Chisel.", auto_file.folder_profiles(conn)
            )
        finally:
            conn.close()
        assert verdict is None


class TestMaybeAutoFile:
    def test_confident_match_files_and_publishes(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            _seed_dump(
                conn, "dump-new", title="Untitled", transcript=WOOD_TRANSCRIPT
            )
            conn.commit()
            filed = auto_file.maybe_auto_file(conn, "dump-new")
            assert filed == "folder-wood"
            row = conn.execute(
                "SELECT folder_id, auto_filed_at, auto_file_prev_folder_id "
                "FROM dumps WHERE id = 'dump-new'"
            ).fetchone()
            assert row["folder_id"] == "folder-wood"
            assert row["auto_filed_at"] is not None
            assert row["auto_file_prev_folder_id"] is None
            feed = conn.execute(
                "SELECT * FROM change_log WHERE entity_id = 'dump-new'"
            ).fetchall()
            assert len(feed) == 1, "the filing must ride the sync feed"
            assert feed[0]["device_id"] == "server"
            payload = json.loads(feed[0]["payload"])
            assert payload["folder_id"] == "folder-wood"
            assert payload["auto_filed_at"] == row["auto_filed_at"]
            assert payload["auto_file_prev_folder_id"] is None
        finally:
            conn.close()

    def test_unsure_match_changes_nothing_and_stays_silent(
        self, temp_data_dir
    ):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            _seed_dump(
                conn,
                "dump-new",
                transcript="Budget review meeting about hiring plans.",
            )
            conn.commit()
            assert auto_file.maybe_auto_file(conn, "dump-new") is None
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-new'"
            ).fetchone()
            assert row["folder_id"] is None
            assert row["auto_filed_at"] is None
            feed = conn.execute(
                "SELECT * FROM change_log WHERE entity_id = 'dump-new'"
            ).fetchall()
            assert feed == [], "unsure means zero noise: no feed entry at all"
        finally:
            conn.close()

    def test_already_filed_dump_is_never_second_guessed(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            _seed_dump(
                conn,
                "dump-new",
                transcript=WOOD_TRANSCRIPT,
                folder_id="folder-cook",
            )
            conn.commit()
            assert auto_file.maybe_auto_file(conn, "dump-new") is None
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-new'"
            ).fetchone()
            assert row["folder_id"] == "folder-cook"
            assert row["auto_filed_at"] is None
        finally:
            conn.close()

    def test_deleted_or_missing_dump_is_a_no_op(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            _seed_dump(conn, "dump-gone", transcript=WOOD_TRANSCRIPT)
            conn.execute(
                "UPDATE dumps SET deleted_at = ? WHERE id = 'dump-gone'",
                (int(time.time()),),
            )
            conn.commit()
            assert auto_file.maybe_auto_file(conn, "dump-gone") is None
            assert auto_file.maybe_auto_file(conn, "dump-never") is None
        finally:
            conn.close()


class _FakeService:
    def __init__(self, text: str) -> None:
        self.result = TranscriptionResult(text=text, segments=[])

    def transcribe(self, audio_path: str, **kwargs) -> TranscriptionResult:
        return self.result


def _seed_job(data_dir: Path) -> str:
    """Corpus + an unfiled dump with a queued job. Returns the audio path."""
    conn = _connect(data_dir)
    try:
        _two_folder_corpus(conn)
        _seed_dump(conn, "dump-auto", title="Auto")
        conn.execute(
            "INSERT INTO jobs (id, request_id, dump_id, status, model) "
            "VALUES ('job-auto', 'request-auto-001', 'dump-auto', 'queued', "
            "'large-v3')"
        )
        conn.commit()
    finally:
        conn.close()
    audio_dir = data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    audio = audio_dir / "dump-auto.opus"
    audio.write_bytes(b"fake-opus-bytes")
    return str(audio)


class TestTranscriptionTrigger:
    def test_finished_transcription_auto_files_a_confident_match(
        self, temp_data_dir, monkeypatch
    ):
        init_db(str(temp_data_dir))
        audio = _seed_job(temp_data_dir)
        monkeypatch.setattr(
            "app.services.job_queue.get_transcription_service",
            lambda: _FakeService(WOOD_TRANSCRIPT),
        )

        run_job_inline("job-auto", audio)

        conn = _connect(temp_data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-auto'"
            ).fetchone()
            feed = conn.execute(
                "SELECT payload FROM change_log WHERE entity_id = 'dump-auto' "
                "ORDER BY seq DESC LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] == "folder-wood"
        assert row["auto_filed_at"] is not None
        payload = json.loads(feed["payload"])
        assert payload["folder_id"] == "folder-wood", (
            "the filing must reach other devices through the sync feed"
        )

    def test_unsure_transcription_leaves_the_dump_unfiled(
        self, temp_data_dir, monkeypatch
    ):
        init_db(str(temp_data_dir))
        audio = _seed_job(temp_data_dir)
        monkeypatch.setattr(
            "app.services.job_queue.get_transcription_service",
            lambda: _FakeService(
                "Budget review meeting about headcount and hiring plans."
            ),
        )

        run_job_inline("job-auto", audio)

        conn = _connect(temp_data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-auto'"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] is None
        assert row["auto_filed_at"] is None

    def test_auto_file_failure_never_fails_the_finished_job(
        self, temp_data_dir, monkeypatch
    ):
        init_db(str(temp_data_dir))
        audio = _seed_job(temp_data_dir)
        monkeypatch.setattr(
            "app.services.job_queue.get_transcription_service",
            lambda: _FakeService(WOOD_TRANSCRIPT),
        )

        def exploding(*args, **kwargs):
            raise RuntimeError("auto-file exploded")

        monkeypatch.setattr(auto_file, "maybe_auto_file", exploding)

        run_job_inline("job-auto", audio)

        conn = _connect(temp_data_dir)
        try:
            job = conn.execute(
                "SELECT status FROM jobs WHERE id = 'job-auto'"
            ).fetchone()
            dump = conn.execute(
                "SELECT transcript FROM dumps WHERE id = 'dump-auto'"
            ).fetchone()
        finally:
            conn.close()
        assert job["status"] == "completed"
        assert dump["transcript"], (
            "the transcript must survive an auto-file failure"
        )


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


def _push(client, token, device_id, payload, dump_id="dump-undo"):
    resp = client.post(
        "/v1/sync/push",
        json={
            "device_id": device_id,
            "changes": [
                {
                    "entity_type": "dump",
                    "entity_id": dump_id,
                    "op": "upsert",
                    "payload": payload,
                }
            ],
        },
        headers=_auth(token),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["results"][0]["status"] == "applied", body
    return body


def _auto_filed_dump(data_dir: Path) -> None:
    """A dump the server auto-filed into folder-wood, markers set."""
    conn = _connect(data_dir)
    try:
        _two_folder_corpus(conn)
        _seed_dump(
            conn, "dump-undo", transcript=WOOD_TRANSCRIPT,
            folder_id="folder-wood",
        )
        conn.execute(
            "UPDATE dumps SET auto_filed_at = ?, "
            "auto_file_prev_folder_id = NULL WHERE id = 'dump-undo'",
            (int(time.time()),),
        )
        conn.commit()
    finally:
        conn.close()


class TestSyncUndoAndFiling:
    def test_device_unfiling_clears_the_auto_file_markers(
        self, authed_client
    ):
        """The client Undo: a pushed folder_id of null moves the dump back
        and retires the chip everywhere."""
        client, token, data_dir = authed_client
        _auto_filed_dump(data_dir)

        _push(
            client, token, "dev-fold",
            {"title": "Capture", "folder_id": None,
             "updated_at": int(time.time())},
        )

        conn = _connect(data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at, auto_file_prev_folder_id "
                "FROM dumps WHERE id = 'dump-undo'"
            ).fetchone()
            feed = conn.execute(
                "SELECT payload FROM change_log WHERE entity_id = 'dump-undo' "
                "ORDER BY seq DESC LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] is None
        assert row["auto_filed_at"] is None
        assert row["auto_file_prev_folder_id"] is None
        payload = json.loads(feed["payload"])
        assert payload["folder_id"] is None
        assert payload["auto_filed_at"] is None

    def test_device_refiling_elsewhere_also_clears_the_markers(
        self, authed_client
    ):
        client, token, data_dir = authed_client
        _auto_filed_dump(data_dir)

        _push(
            client, token, "dev-fold",
            {"title": "Capture", "folder_id": "folder-cook",
             "updated_at": int(time.time())},
        )

        conn = _connect(data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-undo'"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] == "folder-cook"
        assert row["auto_filed_at"] is None

    def test_folderless_push_keeps_filing_and_markers(self, authed_client):
        """An older client's payload (no folder_id key) is not an eraser:
        the filing, the chip and the feed echo all keep the stored values."""
        client, token, data_dir = authed_client
        _auto_filed_dump(data_dir)

        _push(
            client, token, "dev-old-build",
            {"title": "Renamed on an old build",
             "updated_at": int(time.time())},
        )

        conn = _connect(data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-undo'"
            ).fetchone()
            feed = conn.execute(
                "SELECT payload FROM change_log WHERE entity_id = 'dump-undo' "
                "ORDER BY seq DESC LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] == "folder-wood"
        assert row["auto_filed_at"] is not None
        payload = json.loads(feed["payload"])
        assert payload["folder_id"] == "folder-wood", (
            "the republished payload must carry the filing as applied"
        )
        assert payload["auto_filed_at"] is not None

    def test_same_filing_push_keeps_the_markers(self, authed_client):
        """A rename that echoes the current filing is not the user re-filing:
        the chip survives."""
        client, token, data_dir = authed_client
        _auto_filed_dump(data_dir)

        _push(
            client, token, "dev-fold",
            {"title": "Renamed", "folder_id": "folder-wood",
             "updated_at": int(time.time())},
        )

        conn = _connect(data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-undo'"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] == "folder-wood"
        assert row["auto_filed_at"] is not None

    def test_create_route_publishes_the_folder_fields(self, authed_client):
        """Every server-built dump payload names the filing explicitly
        (present-null, never absent), so clients can rely on the key."""
        client, token, data_dir = authed_client
        resp = client.post(
            "/v1/dumps",
            json={
                "id": "dump-0001",
                "mode": "brain_dump",
                "duration_seconds": 5,
                "title": "Fresh",
                "created_at": "2026-09-30T12:00:00Z",
            },
            headers={**_auth(token), "X-Device-Id": "dev-tablet"},
        )
        assert resp.status_code == 201, resp.text
        conn = _connect(data_dir)
        try:
            feed = conn.execute(
                "SELECT payload FROM change_log WHERE entity_id = 'dump-0001'"
            ).fetchone()
        finally:
            conn.close()
        payload = json.loads(feed["payload"])
        assert "folder_id" in payload and payload["folder_id"] is None
        assert "auto_filed_at" in payload
        assert "auto_file_prev_folder_id" in payload
