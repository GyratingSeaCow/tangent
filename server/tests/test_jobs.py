# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/dumps/{id}/transcribe and /v1/jobs/{id} endpoints."""

import json
import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sse_starlette.sse import AppStatus

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.auth import generate_token, hash_token, require_auth
from app.db import get_db, init_db


@pytest.fixture
def authed_client_with_dump(temp_data_dir: Path, monkeypatch):
    init_db(str(temp_data_dir))

    # Stub out the background task runner so tests don't hit real Whisper.
    # Patch the name as imported in app.api.jobs (not just the source module).
    monkeypatch.setattr("app.api.jobs.run_job_inline", lambda jid, ap: None)

    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        # Seed a dump directly (no audio, just metadata)
        now_ts = int(time.time())
        conn.executemany(
            """
            INSERT INTO dumps (id, client_id, mode, duration_seconds, title,
                               created_at, updated_at, audio_kept)
            VALUES (?, 'single-user', 'brain_dump', 60, ?, ?, ?, 0)
            """,
            [
                ("seed-dump-1", "Seeded dump", now_ts, now_ts),
                ("seed-dump-2", "Second dump", now_ts, now_ts),
            ],
        )
        conn.commit()
    finally:
        conn.close()

    # Seed an audio file so transcription enqueue can find it.
    audio_dir = temp_data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    (audio_dir / "seed-dump-1.opus").write_bytes(b"fake-opus-bytes")
    (audio_dir / "seed-dump-2.opus").write_bytes(b"fake-opus-bytes")

    app = FastAPI()
    app.include_router(dumps_router)
    app.include_router(jobs_router)
    return TestClient(app), token, "seed-dump-1"


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_enqueue_transcription_returns_job(authed_client_with_dump):
    """Job row is created synchronously. Background transcription may fail
    because the audio file doesn't exist; we only verify the enqueue side."""
    client, token, dump_id = authed_client_with_dump
    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3", "request_id": "request-enqueue-001"},
        headers=_auth(token),
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["dump_id"] == dump_id
    assert body["request_id"] == "request-enqueue-001"
    assert body["model"] == "large-v3"
    # Job is queued synchronously
    assert body["status"] in ("queued", "running", "completed", "failed")


def test_enqueue_without_model_uses_server_selection(
    authed_client_with_dump, temp_data_dir
):
    """Omitting `model` resolves to the server-selected model (item 1.0b).

    The engine loads the server-selected model regardless of the job row, so
    a hardcoded request default lets the two drift (a job row said large-v3
    while the engine logged model=small). The row must record what the
    engine will actually use.
    """
    client, token, dump_id = authed_client_with_dump
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) "
            "VALUES ('whisper_model', 'small')"
        )
        conn.commit()
    finally:
        conn.close()

    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"request_id": "request-model-omit-001"},
        headers=_auth(token),
    )
    assert resp.status_code == 201
    assert resp.json()["model"] == "small"


def test_enqueue_replay_without_model_reuses_job_model(
    authed_client_with_dump, temp_data_dir
):
    """A model-less replay of an existing request_id must return the original
    job unchanged — not re-resolve the selection and 409 on the mismatch."""
    client, token, dump_id = authed_client_with_dump
    first = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "small", "request_id": "request-model-replay-001"},
        headers=_auth(token),
    )
    assert first.status_code == 201

    # Selection moves on after the job was created.
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) "
            "VALUES ('whisper_model', 'medium')"
        )
        conn.commit()
    finally:
        conn.close()

    replay = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"request_id": "request-model-replay-001"},
        headers=_auth(token),
    )
    assert replay.status_code == 200
    assert replay.json()["id"] == first.json()["id"]
    assert replay.json()["model"] == "small"


def test_get_job_by_id(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    enq = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3", "request_id": "request-poll-001"},
        headers=_auth(token),
    )
    job_id = enq.json()["id"]

    resp = client.get(f"/v1/jobs/{job_id}", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["request_id"] == "request-poll-001"


def test_completed_job_stream_emits_valid_json(
    authed_client_with_dump,
    temp_data_dir: Path,
):
    client, token, dump_id = authed_client_with_dump
    transcript = "Jeff's update:\nready\tto ship\u0001"
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            """
            INSERT INTO jobs (
                id, request_id, dump_id, status, model, completed_at, result_transcript
            ) VALUES (?, 'request-stream-001', ?, 'completed', 'large-v3', ?, ?)
            """,
            ("completed-job", dump_id, int(time.time()), transcript),
        )
        conn.commit()
    finally:
        conn.close()

    resp = client.get("/v1/jobs/completed-job/stream", headers=_auth(token))

    assert resp.status_code == 200
    data_line = next(line for line in resp.text.splitlines() if line.startswith("data: "))
    payload = json.loads(data_line.removeprefix("data: "))
    assert payload == {
        "status": "completed",
        "request_id": "request-stream-001",
        "transcript": transcript,
    }


def test_repeating_request_id_returns_same_job_without_rescheduling(
    authed_client_with_dump, monkeypatch
):
    client, token, dump_id = authed_client_with_dump
    scheduled = []
    monkeypatch.setattr(
        "app.api.jobs.run_job_inline",
        lambda job_id, audio_path: scheduled.append(job_id),
    )
    payload = {"model": "large-v3", "request_id": "request-repeat-001"}
    first = client.post(
        f"/v1/dumps/{dump_id}/transcribe", json=payload, headers=_auth(token)
    )
    second = client.post(
        f"/v1/dumps/{dump_id}/transcribe", json=payload, headers=_auth(token)
    )
    assert first.status_code == 201
    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]
    assert second.json()["request_id"] == "request-repeat-001"
    assert scheduled == [first.json()["id"]]


@pytest.mark.parametrize(
    "dump_id,model", [("seed-dump-1", "small"), ("seed-dump-2", "large-v3")]
)
def test_request_id_conflicts_across_dump_or_model(
    authed_client_with_dump, dump_id, model
):
    client, token, original_dump_id = authed_client_with_dump
    request_id = "request-conflict-001"
    first = client.post(
        f"/v1/dumps/{original_dump_id}/transcribe",
        json={"model": "large-v3", "request_id": request_id},
        headers=_auth(token),
    )
    conflict = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": model, "request_id": request_id},
        headers=_auth(token),
    )
    assert first.status_code == 201
    assert conflict.status_code == 409


def test_omitted_request_id_returns_422(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    response = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert response.status_code == 422


class _Cursor:
    def __init__(self, row):
        self._row = row

    def fetchone(self):
        return self._row


class _StreamDb:
    def __init__(self, request_id: str, *, disappear: bool = False):
        self.request_id = request_id
        self.disappear = disappear
        self.polls = 0

    def execute(self, sql, _params=()):
        if "SELECT * FROM jobs" in sql:
            return _Cursor({"id": "job-stream", "request_id": self.request_id})
        self.polls += 1
        if self.disappear:
            return _Cursor(None)
        return _Cursor(
            {
                "status": "queued",
                "request_id": self.request_id,
                "result_transcript": None,
                "error": None,
            }
        )


def _stream_client(db) -> TestClient:
    AppStatus.should_exit_event = None
    app = FastAPI()
    app.include_router(jobs_router)
    app.dependency_overrides[get_db] = lambda: db
    app.dependency_overrides[require_auth] = lambda: "test-user"
    return TestClient(app)


def _sse_events(response) -> list[tuple[str, dict]]:
    events = []
    current = {}
    for line in response.text.splitlines():
        if not line:
            if current:
                events.append((current["event"], json.loads(current["data"])))
                current = {}
        elif line.startswith("event: "):
            current["event"] = line.removeprefix("event: ")
        elif line.startswith("data: "):
            current["data"] = line.removeprefix("data: ")
    return events


def test_disappeared_job_stream_emits_exact_json_error_event():
    request_id = "request-disappeared-001"
    with _stream_client(_StreamDb(request_id, disappear=True)) as client:
        response = client.get("/v1/jobs/job-stream/stream")
    assert _sse_events(response) == [
        (
            "error",
            {
                "status": "error",
                "request_id": request_id,
                "error": "job disappeared",
            },
        )
    ]


def test_timed_out_job_stream_emits_exact_json_timeout_event(monkeypatch):
    async def no_sleep(_seconds):
        return None

    request_id = "request-timeout-001"
    monkeypatch.setattr("app.api.jobs.asyncio.sleep", no_sleep)
    with _stream_client(_StreamDb(request_id)) as client:
        response = client.get("/v1/jobs/job-stream/stream")
    events = _sse_events(response)
    assert events[-1] == (
        "timeout",
        {
            "status": "timeout",
            "request_id": request_id,
            "error": "job did not complete within 30 minutes",
        },
    )


def test_enqueue_requires_auth(authed_client_with_dump):
    client, _, dump_id = authed_client_with_dump
    resp = client.post(f"/v1/dumps/{dump_id}/transcribe", json={"model": "large-v3"})
    assert resp.status_code == 401


def test_enqueue_for_unknown_dump_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.post(
        "/v1/dumps/does-not-exist/transcribe",
        json={
            "model": "large-v3",
            "request_id": "request-unknown-dump-001",
        },
        headers=_auth(token),
    )
    assert resp.status_code == 404


def test_transcribe_text_note_returns_422_with_exact_detail(authed_client_with_dump):
    """A text_note dump can never be transcribed: 422 with the exact detail,
    not the missing-audio detail it would otherwise fall through to."""
    client, token, _ = authed_client_with_dump
    create = client.post(
        "/v1/dumps",
        json={
            "id": "note-dump-0001-uuid",
            "mode": "text_note",
            "duration_seconds": 0,
            "title": "A typed note",
            "created_at": datetime.now(UTC).isoformat(),
        },
        headers=_auth(token),
    )
    assert create.status_code == 201

    resp = client.post(
        "/v1/dumps/note-dump-0001-uuid/transcribe",
        json={"model": "large-v3", "request_id": "request-note-reject-001"},
        headers=_auth(token),
    )
    assert resp.status_code == 422
    assert resp.json()["detail"] == "Text notes cannot be transcribed"


def test_get_unknown_job_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.get("/v1/jobs/does-not-exist", headers=_auth(token))
    assert resp.status_code == 404
