# SPDX-License-Identifier: AGPL-3.0-or-later
"""Auto-trigger: meeting dumps enqueue a summarize after transcription
completes — gated on exactly mode=meeting AND installed AND toggle enabled
(non-meeting dumps are regenerate-only)."""

from __future__ import annotations

import sqlite3
import sys
import time
from pathlib import Path

import pytest

from app.db import init_db
from app.services import summarizer_worker
from app.services.job_queue import run_job_inline
from app.services.transcription import TranscriptionResult

SEGMENTS = [
    {"start": 0.0, "end": 2.5, "speaker": "S1", "text": "Hello world."},
]


@pytest.fixture(autouse=True)
def _reset_worker():
    summarizer_worker._reset_for_tests()
    yield
    summarizer_worker._reset_for_tests()


class _FakeService:
    def __init__(self) -> None:
        self.result = TranscriptionResult(
            text="Hello world.", segments=list(SEGMENTS)
        )

    def transcribe(
        self, audio_path: str, *, hotwords: str | None = None
    ) -> TranscriptionResult:
        return self.result


def _seed(data_dir: Path, *, mode: str = "meeting") -> str:
    """DB + dump + queued job + audio file. Returns the audio path."""
    init_db(str(data_dir))
    now = int(time.time())
    conn = sqlite3.connect(data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, "
            "created_at, updated_at, audio_kept) "
            "VALUES ('dump-auto', 'single-user', ?, 6, 'Auto', ?, ?, 0)",
            (mode, now, now),
        )
        conn.execute(
            "INSERT INTO jobs (id, request_id, dump_id, status, model) "
            "VALUES ('job-auto', 'request-auto-001', 'dump-auto', 'queued', "
            "'large-v3')"
        )
        conn.commit()
    finally:
        conn.close()
    audio_dir = data_dir / "audio"
    audio_dir.mkdir(exist_ok=True)
    audio = audio_dir / "dump-auto.opus"
    audio.write_bytes(b"fake-opus-bytes")
    return str(audio)


def _set_enabled(data_dir: Path, enabled: bool) -> None:
    conn = sqlite3.connect(data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) "
            "VALUES ('summaries_enabled', ?)",
            ("1" if enabled else "0",),
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def _stubbed_transcription(monkeypatch):
    monkeypatch.setattr(
        "app.services.job_queue.get_transcription_service", lambda: _FakeService()
    )
    # The trigger only ENQUEUES in these tests: no worker thread consumes
    # the entry, so pending() is directly assertable.
    monkeypatch.setattr(
        summarizer_worker, "start_worker_if_installed", lambda: None
    )


def _installed(monkeypatch, yes: bool = True) -> None:
    monkeypatch.setattr(
        summarizer_worker.summarizer_env,
        "python_path",
        (lambda: sys.executable) if yes else (lambda: None),
    )


def test_meeting_job_completion_enqueues_summarize_when_eligible(
    temp_data_dir, monkeypatch, _stubbed_transcription
):
    audio = _seed(temp_data_dir, mode="meeting")
    _set_enabled(temp_data_dir, True)
    _installed(monkeypatch)

    run_job_inline("job-auto", audio)

    assert summarizer_worker.pending() == ["dump-auto"], (
        "a finished meeting transcription must auto-enqueue a summarize"
    )


@pytest.mark.parametrize("mode", ["brain_dump", "text_note"])
def test_non_meeting_job_completion_never_auto_triggers(
    temp_data_dir, monkeypatch, _stubbed_transcription, mode
):
    audio = _seed(temp_data_dir, mode=mode)
    _set_enabled(temp_data_dir, True)
    _installed(monkeypatch)

    run_job_inline("job-auto", audio)

    assert summarizer_worker.pending() == [], "non-meeting dumps are regenerate-only"


def test_toggle_off_suppresses_the_auto_trigger(
    temp_data_dir, monkeypatch, _stubbed_transcription
):
    audio = _seed(temp_data_dir, mode="meeting")
    _set_enabled(temp_data_dir, False)
    _installed(monkeypatch)

    run_job_inline("job-auto", audio)

    assert summarizer_worker.pending() == []


def test_uninstalled_env_suppresses_the_auto_trigger(
    temp_data_dir, monkeypatch, _stubbed_transcription
):
    audio = _seed(temp_data_dir, mode="meeting")
    _set_enabled(temp_data_dir, True)
    _installed(monkeypatch, yes=False)

    run_job_inline("job-auto", audio)

    assert summarizer_worker.pending() == []


def test_trigger_failure_does_not_fail_the_finished_transcription(
    temp_data_dir, monkeypatch, _stubbed_transcription
):
    """The transcript is the primary artifact; a broken trigger must not
    mark the job failed or lose the transcript."""
    audio = _seed(temp_data_dir, mode="meeting")
    _set_enabled(temp_data_dir, True)
    _installed(monkeypatch)

    def exploding(*a, **kw):
        raise RuntimeError("trigger exploded")

    monkeypatch.setattr(summarizer_worker, "maybe_enqueue_auto", exploding)

    run_job_inline("job-auto", audio)

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        job = conn.execute(
            "SELECT status FROM jobs WHERE id = 'job-auto'"
        ).fetchone()
        dump = conn.execute(
            "SELECT transcript FROM dumps WHERE id = 'dump-auto'"
        ).fetchone()
    finally:
        conn.close()
    assert job["status"] == "completed"
    assert dump["transcript"], "the transcript must survive a trigger failure"


def test_trigger_fires_after_the_transcript_is_committed(
    temp_data_dir, monkeypatch, _stubbed_transcription
):
    """The worker reads on its own connection: an enqueue racing an
    uncommitted transcript would summarize nothing. The trigger must observe
    a committed transcript (sync.py's commit-before-wake precedent)."""
    audio = _seed(temp_data_dir, mode="meeting")
    _set_enabled(temp_data_dir, True)
    _installed(monkeypatch)

    seen: list[str | None] = []
    real = summarizer_worker.maybe_enqueue_auto

    def spying(db, dump_id, mode):
        other = sqlite3.connect(temp_data_dir / "tangent.db")
        other.row_factory = sqlite3.Row
        try:
            row = other.execute(
                "SELECT transcript FROM dumps WHERE id = ?", (dump_id,)
            ).fetchone()
        finally:
            other.close()
        seen.append(row["transcript"])
        return real(db, dump_id, mode)

    monkeypatch.setattr(summarizer_worker, "maybe_enqueue_auto", spying)

    run_job_inline("job-auto", audio)

    assert seen and seen[0], (
        "a second connection must already see the committed transcript "
        "when the trigger fires"
    )
    assert summarizer_worker.pending() == ["dump-auto"]
