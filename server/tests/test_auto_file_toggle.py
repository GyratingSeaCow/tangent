# SPDX-License-Identifier: AGPL-3.0-or-later
"""The auto-file toggle: /v1/auto-file/settings persists it server-side
(summaries-toggle precedent), it defaults ON, and switching it off makes
the post-transcription trigger file nothing while the dump and transcript
stay untouched."""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.db import init_db
from app.main import create_app
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
) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, "
        "transcript, folder_id, created_at, updated_at, audio_kept) "
        "VALUES (?, 'single-user', 'brain_dump', 10, ?, ?, ?, ?, ?, 0)",
        (dump_id, title, transcript, folder_id, now, now),
    )


def _two_folder_corpus(conn: sqlite3.Connection) -> None:
    """Woodworking and Cooking folders, each holding on-topic captures —
    a corpus WOOD_TRANSCRIPT files confidently into (test_auto_file's)."""
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


# ---------------------------------------------------------------------------
# service: default + persistence
# ---------------------------------------------------------------------------


class TestServiceToggle:
    def test_defaults_on_when_no_row_exists(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            assert auto_file.auto_file_enabled(conn) is True
        finally:
            conn.close()

    def test_set_and_read_roundtrip(self, temp_data_dir):
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            auto_file.set_auto_file_enabled(conn, False)
            assert auto_file.auto_file_enabled(conn) is False
            auto_file.set_auto_file_enabled(conn, True)
            assert auto_file.auto_file_enabled(conn) is True
        finally:
            conn.close()

    def test_toggle_off_makes_maybe_auto_file_a_no_op(self, temp_data_dir):
        """A transcript the classifier WOULD file confidently must stay
        unfiled while the toggle is off — and the sync feed stays silent."""
        init_db(str(temp_data_dir))
        conn = _connect(temp_data_dir)
        try:
            _two_folder_corpus(conn)
            _seed_dump(conn, "dump-new", transcript=WOOD_TRANSCRIPT)
            conn.commit()
            auto_file.set_auto_file_enabled(conn, False)
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
            assert feed == [], "a disabled trigger makes zero noise"
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# transcription trigger honors the toggle
# ---------------------------------------------------------------------------


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


def _set_enabled(data_dir: Path, enabled: bool) -> None:
    conn = _connect(data_dir)
    try:
        auto_file.set_auto_file_enabled(conn, enabled)
    finally:
        conn.close()


class TestTranscriptionTrigger:
    def test_toggle_off_suppresses_filing_after_transcription(
        self, temp_data_dir, monkeypatch
    ):
        init_db(str(temp_data_dir))
        audio = _seed_job(temp_data_dir)
        _set_enabled(temp_data_dir, False)
        monkeypatch.setattr(
            "app.services.job_queue.get_transcription_service",
            lambda: _FakeService(WOOD_TRANSCRIPT),
        )

        run_job_inline("job-auto", audio)

        conn = _connect(temp_data_dir)
        try:
            job = conn.execute(
                "SELECT status FROM jobs WHERE id = 'job-auto'"
            ).fetchone()
            row = conn.execute(
                "SELECT transcript, folder_id, auto_filed_at FROM dumps "
                "WHERE id = 'dump-auto'"
            ).fetchone()
        finally:
            conn.close()
        assert job["status"] == "completed"
        assert row["transcript"], "the transcript itself must survive"
        assert row["folder_id"] is None
        assert row["auto_filed_at"] is None

    def test_default_on_files_without_any_stored_setting(
        self, temp_data_dir, monkeypatch
    ):
        """No app_settings row at all — the fresh-server state — files."""
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
        finally:
            conn.close()
        assert row["folder_id"] == "folder-wood"
        assert row["auto_filed_at"] is not None

    def test_reenabling_restores_filing(self, temp_data_dir, monkeypatch):
        init_db(str(temp_data_dir))
        audio = _seed_job(temp_data_dir)
        _set_enabled(temp_data_dir, False)
        _set_enabled(temp_data_dir, True)
        monkeypatch.setattr(
            "app.services.job_queue.get_transcription_service",
            lambda: _FakeService(WOOD_TRANSCRIPT),
        )

        run_job_inline("job-auto", audio)

        conn = _connect(temp_data_dir)
        try:
            row = conn.execute(
                "SELECT folder_id FROM dumps WHERE id = 'dump-auto'"
            ).fetchone()
        finally:
            conn.close()
        assert row["folder_id"] == "folder-wood"


# ---------------------------------------------------------------------------
# /v1/auto-file/settings
# ---------------------------------------------------------------------------


@pytest.fixture
def client(temp_data_dir: Path):
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield cli, {"Authorization": f"Bearer {token}"}, temp_data_dir


class TestSettingsApi:
    def test_get_reports_the_default_on(self, client):
        cli, auth, _ = client
        res = cli.get("/v1/auto-file/settings", headers=auth)
        assert res.status_code == 200
        body = res.json()
        assert body == {"enabled": True}

    def test_post_persists_the_toggle_server_side(self, client):
        cli, auth, data_dir = client
        res = cli.post(
            "/v1/auto-file/settings", json={"enabled": False}, headers=auth
        )
        assert res.status_code == 200
        assert res.json()["enabled"] is False
        # Persisted: a fresh GET (fresh db connection) still sees it.
        assert (
            cli.get("/v1/auto-file/settings", headers=auth).json()["enabled"]
            is False
        )
        conn = _connect(data_dir)
        try:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = 'auto_file_enabled'"
            ).fetchone()
        finally:
            conn.close()
        assert row["value"] == "0"

    def test_post_turns_it_back_on(self, client):
        cli, auth, _ = client
        cli.post("/v1/auto-file/settings", json={"enabled": False}, headers=auth)
        res = cli.post(
            "/v1/auto-file/settings", json={"enabled": True}, headers=auth
        )
        assert res.json()["enabled"] is True

    def test_empty_post_changes_nothing(self, client):
        cli, auth, _ = client
        cli.post("/v1/auto-file/settings", json={"enabled": False}, headers=auth)
        res = cli.post("/v1/auto-file/settings", json={}, headers=auth)
        assert res.status_code == 200
        assert res.json()["enabled"] is False

    def test_settings_require_auth(self, client):
        cli, _, _ = client
        assert cli.get("/v1/auto-file/settings").status_code == 401
        assert (
            cli.post(
                "/v1/auto-file/settings", json={"enabled": False}
            ).status_code
            == 401
        )
