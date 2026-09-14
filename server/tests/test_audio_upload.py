# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the audio upload + download endpoints."""

from __future__ import annotations

import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _create_dump(client: TestClient, token: str, dump_id: str) -> str:
    resp = client.post(
        "/v1/dumps",
        json={
            "id": dump_id,
            "mode": "brain_dump",
            "duration_seconds": 5,
            "title": "Audio test",
            "created_at": datetime.now(UTC).isoformat(),
        },
        headers=_auth(token),
    )
    assert resp.status_code == 201, resp.text
    return dump_id


def test_upload_audio_opus(authed_client, temp_data_dir: Path) -> None:
    """Uploading an opus file saves it to disk."""
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-1")
    audio_bytes = b"\x4f\x67\x67\x53" + b"\x00" * 100  # fake opus/ogg header

    resp = client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", audio_bytes, "audio/ogg")},
        headers=_auth(token),
    )
    assert resp.status_code == 204, resp.text

    audio_file = temp_data_dir / "audio" / f"{dump_id}.opus"
    assert audio_file.exists()
    assert audio_file.read_bytes() == audio_bytes


def test_upload_audio_404_on_missing_dump(authed_client) -> None:
    client, token = authed_client
    resp = client.post(
        "/v1/dumps/does-not-exist/audio",
        files={"audio": ("x.opus", b"x", "audio/ogg")},
        headers=_auth(token),
    )
    assert resp.status_code == 404


def test_upload_audio_requires_auth(authed_client) -> None:
    client, _ = authed_client
    resp = client.post(
        "/v1/dumps/anything/audio",
        files={"audio": ("x.opus", b"x", "audio/ogg")},
    )
    assert resp.status_code == 401


def test_get_audio_returns_uploaded_file(authed_client) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-2")
    audio_bytes = b"test-audio-data"

    client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", audio_bytes, "audio/ogg")},
        headers=_auth(token),
    )

    resp = client.get(f"/v1/dumps/{dump_id}/audio", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.content == audio_bytes


def test_get_audio_404_when_not_uploaded(authed_client) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-3")
    resp = client.get(f"/v1/dumps/{dump_id}/audio", headers=_auth(token))
    assert resp.status_code == 404


def test_upload_overwrites_existing(authed_client, temp_data_dir: Path) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-4")

    client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", b"first", "audio/ogg")},
        headers=_auth(token),
    )
    client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", b"second", "audio/ogg")},
        headers=_auth(token),
    )

    resp = client.get(f"/v1/dumps/{dump_id}/audio", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.content == b"second"


def test_transcribe_without_audio_returns_422(authed_client) -> None:
    """Enqueueing transcription without an audio upload returns 422."""
    from app.api.jobs import router as jobs_router

    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-5")

    # Need to also include the jobs router.
    app = client.app
    app.include_router(jobs_router)

    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "tiny", "request_id": "request-audio-missing-001"},
        headers=_auth(token),
    )
    assert resp.status_code == 422
    assert "audio" in resp.json()["detail"].lower()
