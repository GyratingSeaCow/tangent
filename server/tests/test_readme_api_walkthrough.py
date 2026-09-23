# SPDX-License-Identifier: AGPL-3.0-or-later
"""The README's curl walkthrough, executed.

README.md § REST API promises a copy-paste flow: create a dump, upload
audio, enqueue transcription, poll the job, read the dump back.
Documentation drifts; this test runs that exact sequence with the
same routes, payload fields, and status codes the README prints, so
the README cannot lie without failing CI.
"""

import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def walkthrough_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at)"
            " VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    app.include_router(jobs_router)
    return TestClient(app), token


def test_readme_curl_walkthrough(walkthrough_client) -> None:
    client, token = walkthrough_client
    auth = {"Authorization": f"Bearer {token}"}

    # README step 1: create a dump
    resp = client.post(
        "/v1/dumps",
        json={
            "id": "dump-readme-001",
            "mode": "brain_dump",
            "duration_seconds": 5,
            "title": "Grocery thoughts",
            "created_at": datetime.now(UTC).isoformat(),
        },
        headers=auth,
    )
    assert resp.status_code == 201, resp.text
    dump_id = resp.json()["id"]

    # README step 2: upload the audio (multipart, field name 'audio')
    audio_bytes = b"\x4f\x67\x67\x53" + b"\x00" * 100
    resp = client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", audio_bytes, "audio/ogg")},
        headers=auth,
    )
    assert resp.status_code == 204, resp.text

    # README step 3: enqueue transcription
    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3", "request_id": "request-readme-001"},
        headers=auth,
    )
    assert resp.status_code == 201, resp.text
    job_id = resp.json()["id"]

    # README step 4: poll the job
    resp = client.get(f"/v1/jobs/{job_id}", headers=auth)
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] in {"queued", "running", "done", "failed"}

    # README step 5: read the dump (transcript lands here when done)
    resp = client.get(f"/v1/dumps/{dump_id}", headers=auth)
    assert resp.status_code == 200, resp.text
    assert resp.json()["title"] == "Grocery thoughts"
