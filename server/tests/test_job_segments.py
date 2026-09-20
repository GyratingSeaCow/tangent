# SPDX-License-Identifier: AGPL-3.0-or-later
"""Segment-level timestamps: persistence by the job runner + exposure in the job API."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.jobs import router as jobs_router
from app.auth import generate_token, hash_token
from app.db import init_db
from app.services.job_queue import run_job_inline
from app.services.transcription import TranscriptionResult

SEGMENTS = [
    {"start": 0.0, "end": 2.5, "speaker": None, "text": "Hello world."},
    {"start": 2.5, "end": 5.25, "speaker": None, "text": "Second part."},
]


def _seed(data_dir: Path, *, mode: str = "brain_dump") -> str:
    """Create the db, a dump, a queued job and its audio file. Returns the job id."""
    init_db(str(data_dir))
    now = int(time.time())
    conn = sqlite3.connect(data_dir / "tangent.db")
    try:
        conn.execute(
            """
            INSERT INTO dumps (id, client_id, mode, duration_seconds, title,
                               created_at, updated_at, audio_kept)
            VALUES ('dump-seg', 'single-user', ?, 6, 'Segments dump', ?, ?, 0)
            """,
            (mode, now, now),
        )
        conn.execute(
            """
            INSERT INTO jobs (id, request_id, dump_id, status, model)
            VALUES ('job-seg', 'request-seg-001', 'dump-seg', 'queued', 'large-v3')
            """
        )
        conn.commit()
    finally:
        conn.close()

    audio_dir = data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    audio = audio_dir / "dump-seg.opus"
    audio.write_bytes(b"fake-opus-bytes")
    return str(audio)


class _FakeService:
    def __init__(self, result: TranscriptionResult) -> None:
        self.result = result
        self.calls: list[str] = []

    def transcribe(self, audio_path: str) -> TranscriptionResult:
        self.calls.append(audio_path)
        return self.result


def _row(data_dir: Path, job_id: str = "job-seg") -> sqlite3.Row:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Job runner persistence
# --------------------------------------------------------------------------


def test_run_job_inline_persists_segments_as_json(temp_data_dir: Path, monkeypatch) -> None:
    audio_path = _seed(temp_data_dir)
    service = _FakeService(
        TranscriptionResult(text="Hello world. Second part.", segments=list(SEGMENTS))
    )
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: service
    )

    run_job_inline("job-seg", audio_path)

    row = _row(temp_data_dir)
    assert row["status"] == "completed"
    assert row["result_transcript"] == "Hello world. Second part."
    assert json.loads(row["result_segments"]) == SEGMENTS


def test_run_job_inline_persists_empty_segment_list(temp_data_dir: Path, monkeypatch) -> None:
    """No speech is 'ran and found nothing' ([]), not 'never ran' (NULL)."""
    audio_path = _seed(temp_data_dir)
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(TranscriptionResult(text="", segments=[])),
    )

    run_job_inline("job-seg", audio_path)

    row = _row(temp_data_dir)
    assert row["status"] == "completed"
    assert json.loads(row["result_segments"]) == []


def test_run_job_inline_keeps_raw_segments_for_meeting_mode(
    temp_data_dir: Path, monkeypatch
) -> None:
    """Meeting formatting rewrites the transcript but must not touch segment timings."""
    audio_path = _seed(temp_data_dir, mode="meeting")
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(
            TranscriptionResult(
                text="I will send the report. Second part.", segments=list(SEGMENTS)
            )
        ),
    )

    run_job_inline("job-seg", audio_path)

    row = _row(temp_data_dir)
    assert row["status"] == "completed"
    # Meeting mode stores the client's paragraph format: one [MM:SS] marker
    # per paragraph, same-minute null-speaker segments merged into prose.
    assert row["result_transcript"] == "[00:00] Hello world. Second part."
    # ...but segments stay as transcribed.
    assert json.loads(row["result_segments"]) == SEGMENTS


def test_run_job_inline_meeting_without_segments_keeps_plain_text(
    temp_data_dir: Path, monkeypatch
) -> None:
    """No segments -> nothing to format; the plain transcript is stored as-is."""
    audio_path = _seed(temp_data_dir, mode="meeting")
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(
            TranscriptionResult(text="Plain text only.", segments=[])
        ),
    )

    run_job_inline("job-seg", audio_path)

    row = _row(temp_data_dir)
    assert row["status"] == "completed"
    assert row["result_transcript"] == "Plain text only."


def test_run_job_inline_leaves_segments_null_on_failure(
    temp_data_dir: Path, monkeypatch
) -> None:
    audio_path = _seed(temp_data_dir)

    class _Boom:
        def transcribe(self, _audio_path):
            raise RuntimeError("whisper died")

    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: _Boom()
    )

    run_job_inline("job-seg", audio_path)

    row = _row(temp_data_dir)
    assert row["status"] == "failed"
    assert row["result_segments"] is None


def test_run_job_inline_stores_diarized_speaker_labels(
    temp_data_dir: Path, monkeypatch
) -> None:
    """Speaker labels produced by the service survive the round-trip to SQLite."""
    audio_path = _seed(temp_data_dir)
    diarized = [
        {"start": 0.0, "end": 2.5, "speaker": "Speaker 1", "text": "Hello world."},
        {"start": 2.5, "end": 5.25, "speaker": "Speaker 2", "text": "Second part."},
    ]
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(
            TranscriptionResult(text="Hello world. Second part.", segments=diarized)
        ),
    )

    run_job_inline("job-seg", audio_path)

    assert json.loads(_row(temp_data_dir)["result_segments"]) == diarized


# --------------------------------------------------------------------------
# API exposure
# --------------------------------------------------------------------------


@pytest.fixture
def api_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    now = int(time.time())
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", now),
        )
        conn.execute(
            """
            INSERT INTO dumps (id, client_id, mode, duration_seconds, title,
                               created_at, updated_at, audio_kept)
            VALUES ('dump-seg', 'single-user', 'brain_dump', 6, 'Segments dump', ?, ?, 0)
            """,
            (now, now),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(jobs_router)
    return TestClient(app), token


def _insert_job(data_dir: Path, job_id: str, segments_json: str | None) -> None:
    conn = sqlite3.connect(data_dir / "tangent.db")
    try:
        conn.execute(
            """
            INSERT INTO jobs (id, request_id, dump_id, status, model,
                              completed_at, result_transcript, result_segments)
            VALUES (?, ?, 'dump-seg', 'completed', 'large-v3', ?, ?, ?)
            """,
            (
                job_id,
                f"request-{job_id}",
                int(time.time()),
                "Hello world. Second part.",
                segments_json,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def test_get_job_returns_segments_alongside_transcript(
    api_client, temp_data_dir: Path
) -> None:
    client, token = api_client
    _insert_job(temp_data_dir, "job-api-seg", json.dumps(SEGMENTS))

    resp = client.get(
        "/v1/jobs/job-api-seg", headers={"Authorization": f"Bearer {token}"}
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["result_transcript"] == "Hello world. Second part."
    assert body["segments"] == SEGMENTS


def test_get_job_returns_speaker_labels_when_present(
    api_client, temp_data_dir: Path
) -> None:
    client, token = api_client
    diarized = [
        {"start": 0.0, "end": 2.5, "speaker": "Speaker 1", "text": "Hello world."},
        {"start": 2.5, "end": 5.25, "speaker": "Speaker 2", "text": "Second part."},
    ]
    _insert_job(temp_data_dir, "job-api-diarized", json.dumps(diarized))

    resp = client.get(
        "/v1/jobs/job-api-diarized", headers={"Authorization": f"Bearer {token}"}
    )

    assert resp.json()["segments"] == diarized


def test_get_job_segments_is_null_for_legacy_rows(api_client, temp_data_dir: Path) -> None:
    """Jobs completed before this feature have no stored segments — report null, don't invent."""
    client, token = api_client
    _insert_job(temp_data_dir, "job-api-legacy", None)

    resp = client.get(
        "/v1/jobs/job-api-legacy", headers={"Authorization": f"Bearer {token}"}
    )

    assert resp.status_code == 200
    assert resp.json()["segments"] is None


def test_get_job_segments_is_null_when_stored_json_is_corrupt(
    api_client, temp_data_dir: Path
) -> None:
    client, token = api_client
    _insert_job(temp_data_dir, "job-api-corrupt", "{not json")

    resp = client.get(
        "/v1/jobs/job-api-corrupt", headers={"Authorization": f"Bearer {token}"}
    )

    assert resp.status_code == 200
    assert resp.json()["segments"] is None


def test_completed_job_stream_includes_segments(api_client, temp_data_dir: Path) -> None:
    client, token = api_client
    _insert_job(temp_data_dir, "job-stream-seg", json.dumps(SEGMENTS))

    resp = client.get(
        "/v1/jobs/job-stream-seg/stream",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200
    data_line = next(
        line for line in resp.text.splitlines() if line.startswith("data: ")
    )
    payload = json.loads(data_line.removeprefix("data: "))
    assert payload["status"] == "completed"
    assert payload["transcript"] == "Hello world. Second part."
    assert payload["segments"] == SEGMENTS


def test_completed_job_stream_omits_segments_key_for_legacy_rows(
    api_client, temp_data_dir: Path
) -> None:
    """Backward compatibility: no stored segments -> original SSE payload shape."""
    client, token = api_client
    _insert_job(temp_data_dir, "job-stream-legacy", None)

    resp = client.get(
        "/v1/jobs/job-stream-legacy/stream",
        headers={"Authorization": f"Bearer {token}"},
    )

    data_line = next(
        line for line in resp.text.splitlines() if line.startswith("data: ")
    )
    payload = json.loads(data_line.removeprefix("data: "))
    assert "segments" not in payload
    assert payload["transcript"] == "Hello world. Second part."
