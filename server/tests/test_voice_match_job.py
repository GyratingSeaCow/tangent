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
from app.services import voice_book as vb


class _FakeService:
    def __init__(self, result: TranscriptionResult) -> None:
        self.result = result
        self.diarize_calls: list[bool] = []

    def transcribe(
        self,
        audio_path: str,
        *,
        hotwords: str | None = None,
        translate: bool = False,
        diarize: bool = True,
    ) -> TranscriptionResult:
        self.diarize_calls.append(diarize)
        return self.result


def _seed(
    data_dir: Path,
    *,
    speaker_names: dict[str, str] | None = None,
    mode: str = "meeting",
    duration_seconds: int = 6,
) -> tuple[str, str]:
    init_db(str(data_dir))
    now = int(time.time())
    dump_id = "dump-voice-match"
    job_id = "job-voice-match"
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.execute(
        "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, created_at, "
        "updated_at, audio_kept, speaker_names) VALUES (?, 'single-user', ?, ?, "
        "'Voice match', ?, ?, 0, ?)",
        (
            dump_id,
            mode,
            duration_seconds,
            now,
            now,
            json.dumps(speaker_names) if speaker_names is not None else None,
        ),
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


def test_long_brain_dump_gets_speaker_sections_and_embeddings(
    temp_data_dir: Path, monkeypatch
) -> None:
    job_id, audio_path = _seed(
        temp_data_dir, mode="brain_dump", duration_seconds=31
    )
    service = _FakeService(_voice_result())
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: service
    )

    run_job_inline(job_id, audio_path)

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT * FROM dumps WHERE id = ?", ("dump-voice-match",)
    ).fetchone()
    assert service.diarize_calls == [True]
    assert row["transcript"] == "## Speaker 1\n\nhello\n\n## Speaker 2\n\nthere"
    assert json.loads(row["speaker_embeddings"]) == _voice_result().speaker_embeddings
    conn.close()


def test_thirty_second_brain_dump_stays_byte_identical_plain_text(
    temp_data_dir: Path, monkeypatch
) -> None:
    job_id, audio_path = _seed(
        temp_data_dir, mode="brain_dump", duration_seconds=30
    )
    result = _voice_result()
    result.text = "hello  there\nexact bytes"
    result.speaker_embeddings = None
    service = _FakeService(result)
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: service
    )

    run_job_inline(job_id, audio_path)

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        "SELECT * FROM dumps WHERE id = ?", ("dump-voice-match",)
    ).fetchone()
    assert service.diarize_calls == [False]
    assert row["transcript"] == "hello  there\nexact bytes"
    assert row["speaker_embeddings"] is None
    conn.close()


def _voice_result() -> TranscriptionResult:
    return TranscriptionResult(
        text="hello",
        segments=[
            {"start": 0.0, "end": 1.0, "speaker": "Speaker 1", "text": "hello"},
            {"start": 1.0, "end": 2.0, "speaker": "Speaker 2", "text": "there"},
        ],
        speaker_embeddings={"Speaker 1": [1.0, 0.05], "Speaker 2": [0.0, 1.0]},
    )


def _run_seeded_job(data_dir: Path, monkeypatch, *, speaker_names=None):
    job_id, audio_path = _seed(data_dir, speaker_names=speaker_names)
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(_voice_result()),
    )
    run_job_inline(job_id, audio_path)
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    row = conn.execute("SELECT * FROM dumps WHERE id = 'dump-voice-match'").fetchone()
    return conn, row


def test_job_auto_names_when_map_empty(temp_data_dir: Path, monkeypatch) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    vb.teach(conn, "Jeff", [1.0, 0.0])
    conn.commit()
    conn.close()
    conn, row = _run_seeded_job(temp_data_dir, monkeypatch)
    assert json.loads(row["speaker_names"]) == {"Speaker 1": "Jeff"}
    assert vb.load_voice_book(conn)[0].samples == 1
    conn.close()


def test_job_never_overwrites_existing_map(temp_data_dir: Path, monkeypatch) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    vb.teach(conn, "Jeff", [1.0, 0.0])
    conn.commit()
    conn.close()
    conn, row = _run_seeded_job(
        temp_data_dir, monkeypatch, speaker_names={"Speaker 1": "Tom"}
    )
    assert json.loads(row["speaker_names"]) == {"Speaker 1": "Tom"}
    conn.close()


def test_job_empty_book_leaves_map_null(temp_data_dir: Path, monkeypatch) -> None:
    conn, row = _run_seeded_job(temp_data_dir, monkeypatch)
    assert row["speaker_names"] is None
    conn.close()
