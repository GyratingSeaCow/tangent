# SPDX-License-Identifier: AGPL-3.0-or-later
"""Integration test: full app boots, routes are mounted, setup flow works."""

import sqlite3
from pathlib import Path

from fastapi.testclient import TestClient

from app.db import init_db
from app.main import create_app


def test_app_boots_and_serves_setup(temp_data_dir: Path):
    app = create_app()
    client = TestClient(app)

    # GET /v1/server/info without auth → 401
    resp = client.get("/v1/server/info")
    assert resp.status_code == 401

    # POST /v1/setup → 200 with token
    resp = client.post("/v1/setup", json={"display_name": "Jeff"})
    assert resp.status_code == 200
    token = resp.json()["token"]
    assert len(token) >= 32

    # GET /v1/server/info with auth → 200
    resp = client.get("/v1/server/info", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["setup_complete"] is True


def test_app_lifespan_creates_data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("TANGENT_DATA_DIR", str(tmp_path / "fresh_data"))

    app = create_app()
    with TestClient(app):
        pass  # Lifespan runs on enter, cleanup on exit

    assert (tmp_path / "fresh_data").exists()
    assert (tmp_path / "fresh_data" / "tangent.db").exists()


def test_app_lifespan_fails_interrupted_jobs(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    db_path = temp_data_dir / "tangent.db"
    with sqlite3.connect(db_path) as db:
        db.execute(
            """
            INSERT INTO dumps (
                id, client_id, created_at, updated_at, mode,
                duration_seconds, title
            ) VALUES ('dump-1', 'client-1', 1, 1, 'brain_dump', 1, 'Dump')
            """
        )
        for job_id, status in (
            ('job-queued', 'queued'),
            ('job-running', 'running'),
            ('job-completed', 'completed'),
            ('job-failed', 'failed'),
        ):
            db.execute(
                """
                INSERT INTO jobs (
                    id, request_id, dump_id, status, model,
                    started_at, completed_at, result_transcript, error
                ) VALUES (?, ?, 'dump-1', ?, 'large-v3', 2, NULL, NULL, ?)
                """,
                (
                    job_id,
                    f'request-{job_id}',
                    status,
                    'existing failure' if status == 'failed' else None,
                ),
            )

    with TestClient(create_app()):
        pass

    with sqlite3.connect(db_path) as db:
        rows = {
            row[0]: (row[1], row[2], row[3])
            for row in db.execute(
                "SELECT id, status, completed_at, error FROM jobs ORDER BY id"
            )
        }

    restart_error = 'Server restarted before transcription completed'
    assert rows['job-queued'][0] == 'failed'
    assert rows['job-queued'][1] is not None
    assert rows['job-queued'][2] == restart_error
    assert rows['job-running'][0] == 'failed'
    assert rows['job-running'][1] is not None
    assert rows['job-running'][2] == restart_error
    assert rows['job-completed'][0] == 'completed'
    assert rows['job-completed'][2] is None
    assert rows['job-failed'][0] == 'failed'
    assert rows['job-failed'][2] == 'existing failure'
