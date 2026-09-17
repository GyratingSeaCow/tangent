# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the audio upload + download endpoints."""

from __future__ import annotations

import asyncio
import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.dumps import upload_audio
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


class _PausedUpload:
    filename = "replacement.opus"
    content_type = "audio/ogg"

    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self._reads = 0

    async def read(self, _size: int) -> bytes:
        self._reads += 1
        if self._reads == 1:
            self.started.set()
            return b"new-"
        if self._reads == 2:
            await self.release.wait()
            return b"audio"
        return b""


@pytest.mark.asyncio
async def test_upload_publishes_only_after_the_body_is_complete(
    authed_client,
    temp_data_dir: Path,
) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-atomic")
    target = temp_data_dir / "audio" / f"{dump_id}.opus"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"old-complete-audio")
    upload = _PausedUpload()
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    try:
        task = asyncio.create_task(upload_audio(dump_id, upload, db, "test-user"))
        await asyncio.wait_for(upload.started.wait(), timeout=0.2)
        await asyncio.sleep(0)

        assert target.read_bytes() == b"old-complete-audio"

        upload.release.set()
        response = await asyncio.wait_for(task, timeout=0.2)
        assert response.status_code == 204
        assert target.read_bytes() == b"new-audio"
    finally:
        upload.release.set()
        db.close()


class _FailingUpload:
    filename = "replacement.opus"
    content_type = "audio/ogg"

    def __init__(self) -> None:
        self._reads = 0

    async def read(self, _size: int) -> bytes:
        self._reads += 1
        if self._reads == 1:
            return b"partial"
        raise OSError("client disconnected")


@pytest.mark.asyncio
async def test_failed_upload_preserves_existing_audio_and_removes_temp(
    authed_client,
    temp_data_dir: Path,
) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-failed-replacement")
    target = temp_data_dir / "audio" / f"{dump_id}.opus"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"old-complete-audio")
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    try:
        with pytest.raises(OSError, match="client disconnected"):
            await upload_audio(dump_id, _FailingUpload(), db, "test-user")
    finally:
        db.close()

    assert target.read_bytes() == b"old-complete-audio"
    assert list(target.parent.glob(f".{target.name}.*.upload")) == []


def test_empty_upload_preserves_existing_audio(
    authed_client,
    temp_data_dir: Path,
) -> None:
    client, token = authed_client
    dump_id = _create_dump(client, token, "test-dump-empty-replacement")
    target = temp_data_dir / "audio" / f"{dump_id}.opus"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"old-complete-audio")

    response = client.post(
        f"/v1/dumps/{dump_id}/audio",
        files={"audio": (f"{dump_id}.opus", b"", "audio/ogg")},
        headers=_auth(token),
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "Uploaded audio is empty"
    assert target.read_bytes() == b"old-complete-audio"
    assert list(target.parent.glob(f".{target.name}.*.upload")) == []


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


def test_upload_audio_rejected_for_text_note(authed_client, temp_data_dir: Path) -> None:
    """Text notes must never accept audio bytes — 422, nothing written."""
    client, token = authed_client
    resp = client.post(
        "/v1/dumps",
        json={
            "id": "note-dump-1",
            "mode": "text_note",
            "duration_seconds": 0,
            "title": "Note",
            "created_at": datetime.now(UTC).isoformat(),
        },
        headers=_auth(token),
    )
    assert resp.status_code == 201, resp.text

    resp = client.post(
        "/v1/dumps/note-dump-1/audio",
        files={"audio": ("note-dump-1.opus", b"\x4f\x67\x67\x53" + b"\x00" * 10, "audio/ogg")},
        headers=_auth(token),
    )
    assert resp.status_code == 422
    assert "Text notes" in resp.json()["detail"]
    audio_dir = temp_data_dir / "audio"
    assert not list(audio_dir.glob("note-dump-1.*")) if audio_dir.exists() else True
