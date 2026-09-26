# SPDX-License-Identifier: AGPL-3.0-or-later
"""Word timestamps, dump promotion/backfill, and dump sync payloads."""

from __future__ import annotations

import json
import math
import sqlite3
import time
from pathlib import Path
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import _publish_dump_change
from app.api.dumps import router as dumps_router
from app.api.sync import router as sync_router
from app.auth import generate_token, hash_token
from app.db import SCHEMA, init_db
from app.services.job_queue import run_job_inline
from app.services.transcription import (
    TranscriptionResult,
    TranscriptionService,
    compute_waveform_peaks,
)

TIMINGS = [
    {
        "start": 0.0,
        "end": 1.5,
        "speaker": "Speaker 1",
        "text": "Hello world.",
        "words": [
            {"w": "Hello", "s": 0.0, "e": 0.55, "p": 0.98},
            {"w": "world.", "s": 0.6, "e": 1.5, "p": 0.87},
        ],
    }
]


def _connect(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _seed_dump_and_job(data_dir: Path, *, timings: str | None = None) -> str:
    init_db(str(data_dir))
    now = int(time.time())
    conn = _connect(data_dir)
    try:
        conn.execute(
            """
            INSERT INTO dumps
                (id, client_id, created_at, updated_at, mode, duration_seconds,
                 title, transcript, transcript_timings, timings_version,
                 audio_kept)
            VALUES ('dump-timing', 'single-user', ?, ?, 'brain_dump', 2,
                    'Timing dump', 'old text', ?, ?, 0)
            """,
            (now, now, timings, 1 if timings is not None else None),
        )
        conn.execute(
            """
            INSERT INTO jobs (id, request_id, dump_id, status, model)
            VALUES ('job-timing', 'request-timing-001', 'dump-timing',
                    'queued', 'large-v3')
            """
        )
        conn.commit()
    finally:
        conn.close()
    audio = data_dir / "audio" / "dump-timing.opus"
    audio.parent.mkdir(exist_ok=True)
    audio.write_bytes(b"fake audio")
    return str(audio)


class _FakeService:
    def __init__(self, result: TranscriptionResult) -> None:
        self.result = result

    def transcribe(
        self, _audio_path: str, *, hotwords: str | None = None
    ) -> TranscriptionResult:
        return self.result


def test_transcribe_requests_word_timestamps_and_emits_compact_words(monkeypatch, tmp_path):
    class FakeModel:
        def __init__(self) -> None:
            self.kwargs = None

        def transcribe(self, _audio_path, **kwargs):
            self.kwargs = kwargs
            words = [
                SimpleNamespace(word=" Hello", start=0, end=0.55, probability=0.98),
                SimpleNamespace(word=" world.", start=0.6, end=1.5, probability=0.87),
            ]
            segment = SimpleNamespace(
                start=0, end=1.5, text=" Hello world. ", words=words
            )
            return [segment], SimpleNamespace(language="en")

    model = FakeModel()
    service = TranscriptionService(model_name="large-v3")
    service._model = model
    samples = [
        math.sin(2 * math.pi * 440 * i / 16000) if i < 8000 else 0.0
        for i in range(16000)
    ]
    monkeypatch.setattr(
        "app.services.transcription._decode_audio_samples", lambda _path: samples
    )
    monkeypatch.setattr(
        "app.services.transcription.diarize_segments", lambda _path, segments: segments
    )

    result = service.transcribe(str(tmp_path / "audio.wav"))

    assert model.kwargs["word_timestamps"] is True
    assert result.segments[0]["words"] == TIMINGS[0]["words"]
    assert len(result.peaks) == 600
    assert max(result.peaks[:300]) == 1.0
    assert sum(result.peaks[:300]) / 300 >= 0.9
    assert result.peaks[-1] == 0.0


def test_waveform_peaks_short_clip_still_has_600_buckets():
    peaks = compute_waveform_peaks([1.0, -1.0])

    assert len(peaks) == 600
    assert max(peaks) == 1.0
    assert peaks.count(1.0) == 2


def test_completion_promotes_timings_to_dump(temp_data_dir: Path, monkeypatch):
    audio = _seed_dump_and_job(temp_data_dir)
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service",
        lambda: _FakeService(
            TranscriptionResult(text="Hello world.", segments=TIMINGS, peaks=[1.0, 0.0])
        ),
    )

    run_job_inline("job-timing", audio)

    conn = _connect(temp_data_dir)
    try:
        row = conn.execute(
            "SELECT transcript_timings, timings_version FROM dumps "
            "WHERE id = 'dump-timing'"
        ).fetchone()
    finally:
        conn.close()
    assert json.loads(row["transcript_timings"]) == {
        "segments": TIMINGS,
        "peaks": [1.0, 0.0],
    }
    assert row["timings_version"] == 1


def test_retranscribe_start_clears_stale_timings(temp_data_dir: Path, monkeypatch):
    audio = _seed_dump_and_job(temp_data_dir, timings=json.dumps(TIMINGS))

    class InspectingService:
        def transcribe(
            self, _audio_path: str, *, hotwords: str | None = None
        ) -> TranscriptionResult:
            conn = _connect(temp_data_dir)
            try:
                row = conn.execute(
                    "SELECT transcript_timings, timings_version FROM dumps "
                    "WHERE id = 'dump-timing'"
                ).fetchone()
            finally:
                conn.close()
            conn = _connect(temp_data_dir)
            try:
                change = conn.execute(
                    "SELECT payload FROM change_log WHERE entity_id = 'dump-timing' "
                    "ORDER BY seq DESC LIMIT 1"
                ).fetchone()
            finally:
                conn.close()
            payload = json.loads(change["payload"])
            # Record what we saw rather than asserting here: an assert
            # inside transcribe() is swallowed by the job runner's
            # except-Exception (the job just fails) and the test would
            # pass vacuously. Sabotage-proven: the clear was removed and
            # the original form of this test stayed green.
            seen["row"] = (row["transcript_timings"], row["timings_version"])
            seen["payload"] = (
                payload["transcript_timings"],
                payload["timings_version"],
            )
            return TranscriptionResult(text="replacement", segments=[])

    seen: dict = {}
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", InspectingService
    )
    run_job_inline("job-timing", audio)
    assert seen, "transcribe() never ran"
    assert seen["row"] == (None, None), "stale timings survived job start"
    assert seen["payload"] == (None, None), "clear was not published to sync"
    conn = _connect(temp_data_dir)
    try:
        status = conn.execute(
            "SELECT status FROM jobs WHERE id = 'job-timing'"
        ).fetchone()["status"]
    finally:
        conn.close()
    assert status == "completed"


def test_dump_edit_leaves_timings_intact(temp_data_dir: Path):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    token = generate_token()
    conn = _connect(temp_data_dir)
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, 'Test', ?)",
            (hash_token(token), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    app = FastAPI()
    app.include_router(dumps_router)
    client = TestClient(app)

    response = client.patch(
        "/v1/dumps/dump-timing",
        json={"title": "Edited title"},
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    assert response.json()["transcript_timings"] == stored
    assert response.json()["timings_version"] == 1
    conn = _connect(temp_data_dir)
    try:
        row = conn.execute(
            "SELECT transcript_timings, timings_version FROM dumps "
            "WHERE id = 'dump-timing'"
        ).fetchone()
    finally:
        conn.close()
    assert row["transcript_timings"] == stored
    assert row["timings_version"] == 1


def test_get_dump_exposes_timing_fields(temp_data_dir: Path):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    token = generate_token()
    conn = _connect(temp_data_dir)
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, 'Test', ?)",
            (hash_token(token), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    app = FastAPI()
    app.include_router(dumps_router)

    response = TestClient(app).get(
        "/v1/dumps/dump-timing",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    assert response.json()["transcript_timings"] == stored
    assert response.json()["timings_version"] == 1


def test_backfill_uses_latest_completed_segments_and_adds_empty_words(
    temp_data_dir: Path,
):
    db_path = temp_data_dir / "tangent.db"
    legacy = SCHEMA.replace("    transcript_timings TEXT,\n", "").replace(
        "    timings_version INTEGER,\n", ""
    )
    conn = sqlite3.connect(db_path)
    conn.executescript(legacy)
    conn.close()
    conn = _connect(temp_data_dir)
    segment = {"start": 2.0, "end": 3.0, "speaker": None, "text": "latest"}
    try:
        conn.execute(
            "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
            "duration_seconds, title, audio_kept) VALUES "
            "('needs-backfill', 'c', 1, 1, 'brain_dump', 3, 'Old', 0)"
        )
        conn.execute(
            "INSERT INTO jobs (id, request_id, dump_id, status, model, "
            "completed_at, result_segments) VALUES "
            "('job-old', 'req-old-1', 'needs-backfill', 'completed', 'm', 10, ?),"
            "('job-new', 'req-new-1', 'needs-backfill', 'completed', 'm', 20, ?)",
            (json.dumps([{**segment, "text": "older"}]), json.dumps([segment])),
        )
        conn.commit()
    finally:
        conn.close()

    init_db(str(temp_data_dir))

    conn = _connect(temp_data_dir)
    try:
        row = conn.execute(
            "SELECT transcript_timings, timings_version FROM dumps "
            "WHERE id = 'needs-backfill'"
        ).fetchone()
    finally:
        conn.close()
    assert json.loads(row["transcript_timings"]) == {
        "segments": [{**segment, "words": []}],
        "peaks": [],
    }
    assert row["timings_version"] == 1
    conn = _connect(temp_data_dir)
    try:
        change = conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'needs-backfill' "
            "ORDER BY seq DESC LIMIT 1"
        ).fetchone()
    finally:
        conn.close()
    assert json.loads(change["payload"])["transcript_timings"] is not None


def test_backfill_does_not_overwrite_existing_timings(temp_data_dir: Path):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    conn = _connect(temp_data_dir)
    try:
        conn.execute(
            "UPDATE jobs SET status = 'completed', completed_at = 20, "
            "result_segments = ? WHERE id = 'job-timing'",
            (json.dumps([{"start": 9, "end": 10, "speaker": None, "text": "new"}]),),
        )
        conn.commit()
    finally:
        conn.close()

    init_db(str(temp_data_dir))

    conn = _connect(temp_data_dir)
    try:
        row = conn.execute(
            "SELECT transcript_timings FROM dumps WHERE id = 'dump-timing'"
        ).fetchone()
    finally:
        conn.close()
    assert row["transcript_timings"] == stored


def test_startup_does_not_restore_timings_cleared_by_retranscription(
    temp_data_dir: Path,
):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    conn = _connect(temp_data_dir)
    try:
        conn.execute(
            "UPDATE jobs SET status = 'completed', completed_at = 20, "
            "result_segments = ? WHERE id = 'job-timing'",
            (stored,),
        )
        conn.execute(
            "UPDATE dumps SET transcript_timings = NULL, timings_version = NULL "
            "WHERE id = 'dump-timing'"
        )
        conn.commit()
    finally:
        conn.close()

    init_db(str(temp_data_dir))

    conn = _connect(temp_data_dir)
    try:
        row = conn.execute(
            "SELECT transcript_timings FROM dumps WHERE id = 'dump-timing'"
        ).fetchone()
    finally:
        conn.close()
    assert row["transcript_timings"] is None


def test_sync_push_republishes_server_timing_truth(temp_data_dir: Path):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    token = generate_token()
    conn = _connect(temp_data_dir)
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, 'Test', ?)",
            (hash_token(token), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    app = FastAPI()
    app.include_router(sync_router)

    response = TestClient(app).post(
        "/v1/sync/push",
        json={
            "device_id": "device-edit-1",
            "changes": [
                {
                    "entity_type": "dump",
                    "entity_id": "dump-timing",
                    "op": "upsert",
                    "payload": {
                        "transcript": "edited text",
                        "transcript_timings": None,
                        "timings_version": None,
                    },
                }
            ],
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    conn = _connect(temp_data_dir)
    try:
        change = conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-timing' "
            "ORDER BY seq DESC LIMIT 1"
        ).fetchone()
    finally:
        conn.close()
    payload = json.loads(change["payload"])
    assert payload["transcript_timings"] == stored
    assert payload["timings_version"] == 1


def test_sync_feed_payload_carries_timing_fields(temp_data_dir: Path):
    stored = json.dumps(TIMINGS)
    _seed_dump_and_job(temp_data_dir, timings=stored)
    conn = _connect(temp_data_dir)
    try:
        _publish_dump_change(conn, "dump-timing", None)
        conn.commit()
        row = conn.execute(
            "SELECT payload FROM change_log WHERE entity_id = 'dump-timing' "
            "ORDER BY seq DESC"
        ).fetchone()
    finally:
        conn.close()

    payload = json.loads(row["payload"])
    assert payload["transcript_timings"] == stored
    assert payload["timings_version"] == 1
