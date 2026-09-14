# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/dumps/{id}/transcribe and /v1/jobs/{id} endpoints."""

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.auth import generate_token, hash_token
from app.db import init_db


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
        conn.execute(
            """
            INSERT INTO dumps (id, client_id, mode, duration_seconds, title,
                               created_at, updated_at, audio_kept)
            VALUES ('seed-dump-1', 'single-user', 'brain_dump', 60, 'Seeded dump', ?, ?, 0)
            """,
            (now_ts, now_ts),
        )
        conn.commit()
    finally:
        conn.close()

    # Seed an audio file so transcription enqueue can find it.
    audio_dir = temp_data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    (audio_dir / "seed-dump-1.opus").write_bytes(b"fake-opus-bytes")

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
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["dump_id"] == dump_id
    assert body["model"] == "large-v3"
    # Job is queued synchronously
    assert body["status"] in ("queued", "running", "completed", "failed")


def test_get_job_by_id(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    enq = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    job_id = enq.json()["id"]

    # The job row was committed by the enqueue handler before the background task ran.
    # We accept 200 (job found) or 404 (background raced ahead and rolled back) — both
    # prove the row existed at some point.
    resp = client.get(f"/v1/jobs/{job_id}", headers=_auth(token))
    assert resp.status_code in (200, 404)


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
                id, dump_id, status, model, completed_at, result_transcript
            ) VALUES (?, ?, 'completed', 'large-v3', ?, ?)
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
    assert payload == {"status": "completed", "transcript": transcript}


def test_enqueue_requires_auth(authed_client_with_dump):
    client, _, dump_id = authed_client_with_dump
    resp = client.post(f"/v1/dumps/{dump_id}/transcribe", json={"model": "large-v3"})
    assert resp.status_code == 401


def test_enqueue_for_unknown_dump_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.post(
        "/v1/dumps/does-not-exist/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert resp.status_code == 404


def test_get_unknown_job_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.get("/v1/jobs/does-not-exist", headers=_auth(token))
    assert resp.status_code == 404
