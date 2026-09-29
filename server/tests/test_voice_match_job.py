# SPDX-License-Identifier: AGPL-3.0-or-later
"""Voice centroid persistence and automatic matching in the job runner."""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

from app.db import init_db
from app.services.job_queue import run_job_inline
from app.services.transcription import TranscriptionResult


class _FakeService:
    def __init__(self, result: TranscriptionResult) -> None:
        self.result = result

    def transcribe(
        self, audio_path: str, *, hotwords: str | None = None, translate: bool = False
    ) -> TranscriptionResult:
        return self.result


def _seed(data_dir: Path, *, speaker_names: dict[str, str] | None = None) -> tuple[str, str]:
    init_db(str(data_dir))
    now = int(time.time())
    dump_id = "dump-voice-match"
    job_id = "job-voice-match"
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.execute(
        "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, created_at, "
        "updated_at, audio_kept, speaker_names) VALUES (?, 'single-user', 'meeting', 6, "
        "'Voice match', ?, ?, 0, ?)",
        (dump_id, now, now, json.dumps(speaker_names) if speaker_names is not None else None),
    )
    conn.execute(
        "INSERT INTO jobs (id, request_id, dump_id, status, model) "
        "VALUES (?, 'request-voice-match', ?, 'queued', 'large-v3')",
        (job_id, dump_id),
    )
    conn.commit()
    conn.close()
    audio_dir = data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    audio = audio_dir / f"{dump_id}.opus"
    audio.write_bytes(b"fake-opus-bytes")
    return job_id, str(audio)


def _run(data_dir: Path, monkeypatch, result: TranscriptionResult, *, speaker_names=None):
    job_id, audio_path = _seed(data_dir, speaker_names=speaker_names)
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: _FakeService(result)
    )
    run_job_inline(job_id, audio_path)
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn, conn.execute(
        "SELECT * FROM dumps WHERE id = 'dump-voice-match'"
    ).fetchone()


def test_job_stores_speaker_embeddings(temp_data_dir: Path, monkeypatch) -> None:
    result = TranscriptionResult(
        text="hi",
        segments=[{"start": 0.0, "end": 1.0, "speaker": "Speaker 1", "text": "hi"}],
        peaks=[],
        language="en",
        speaker_embeddings={"Speaker 1": [1.0, 0.0]},
    )
    conn, row = _run(temp_data_dir, monkeypatch, result)
    assert json.loads(row["speaker_embeddings"]) == {"Speaker 1": [1.0, 0.0]}
    conn.close()


def test_job_without_embeddings_stores_null(temp_data_dir: Path, monkeypatch) -> None:
    result = TranscriptionResult(text="hi", segments=[], speaker_embeddings=None)
    conn, row = _run(temp_data_dir, monkeypatch, result)
    assert row["speaker_embeddings"] is None
    conn.close()
