# SPDX-License-Identifier: AGPL-3.0-or-later
"""Wire-contract tests for v1.19 translation and summary status."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace

from app.api.sync import _apply_dump
from app.db import SCHEMA, init_db
from app.models import SyncChange
from app.services import summarizer_worker
from app.services.job_queue import run_job_inline
from app.services.transcription import TranscriptionResult, TranscriptionService


def _insert_dump(db: sqlite3.Connection, dump_id: str, transcript: str = "hello") -> None:
    db.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept) "
        "VALUES (?, 'c', 1, 1, 'meeting', 1, 'T', ?, 0)",
        (dump_id, transcript),
    )
    db.commit()


def test_five_column_migrations_are_idempotent_and_republish_once(temp_data_dir: Path):
    path = temp_data_dir / "tangent.db"
    legacy = SCHEMA
    for line in (
        "    language TEXT,\n",
        "    translated INTEGER NOT NULL DEFAULT 0,\n",
        "    summary_status TEXT CHECK (summary_status IN ('queued', 'running', 'failed')),\n",
        "    summary_error TEXT,\n",
        "    summary_queue_position INTEGER,\n",
    ):
        legacy = legacy.replace(line, "")
    conn = sqlite3.connect(path)
    conn.executescript(legacy)
    _insert_dump(conn, "legacy")
    conn.execute(
        "INSERT INTO change_log (entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES ('dump', 'legacy', 'upsert', 'server', '{}', 1)"
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    columns = {row[1] for row in conn.execute("PRAGMA table_info(dumps)")}
    changes = conn.execute(
        "SELECT payload FROM change_log WHERE entity_id = 'legacy' ORDER BY seq"
    ).fetchall()
    conn.close()
    assert {"language", "translated", "summary_status", "summary_error", "summary_queue_position"} <= columns
    assert len(changes) == 2
    payload = json.loads(changes[-1]["payload"])
    assert {key: payload[key] for key in (
        "language", "translated", "summary_status", "summary_error", "summary_queue_position"
    )} == {
        "language": None,
        "translated": False,
        "summary_status": None,
        "summary_error": None,
        "summary_queue_position": None,
    }


def test_translate_true_passes_translate_task_and_returns_language(monkeypatch, tmp_path):
    seen: dict = {}

    class Model:
        def transcribe(self, audio, **kwargs):
            seen.update(kwargs)
            return ([SimpleNamespace(start=0, end=1, text="hello", words=[])], SimpleNamespace(language="es"))

    monkeypatch.setattr("app.services.transcription._decode_audio_samples", lambda _: [0.0])
    service = TranscriptionService("tiny")
    service._model = Model()
    result = service.transcribe(str(tmp_path / "a.wav"), translate=True)
    assert seen["task"] == "translate"
    assert result.language == "es"


def test_job_completion_writes_language_and_translated_with_transcript(temp_data_dir, monkeypatch):
    init_db(str(temp_data_dir))
    audio = temp_data_dir / "audio.wav"
    audio.write_bytes(b"x")
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    _insert_dump(conn, "d")
    conn.execute(
        "INSERT INTO jobs (id, request_id, dump_id, status, model) "
        "VALUES ('j', 'request-v119', 'd', 'queued', 'tiny')"
    )
    conn.commit()
    conn.close()

    class Service:
        def transcribe(self, path, **kwargs):
            assert kwargs["translate"] is True
            return TranscriptionResult(text="English", language="es")

    monkeypatch.setattr("app.services.job_queue.get_transcription_service", Service)
    run_job_inline("j", str(audio), True)
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    row = conn.execute("SELECT transcript, language, translated FROM dumps WHERE id='d'").fetchone()
    conn.close()
    assert row == ("English", "es", 1)



def test_queue_positions_and_summary_terminal_states(temp_data_dir):
    init_db(str(temp_data_dir))
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    _insert_dump(db, "d1")
    _insert_dump(db, "d2")
    summarizer_worker._reset_for_tests()
    try:
        summarizer_worker.enqueue("d1", db)
        summarizer_worker.enqueue("d2", db)
        rows = db.execute(
            "SELECT id, summary_status, summary_queue_position FROM dumps ORDER BY id"
        ).fetchall()
        assert [(r["summary_status"], r["summary_queue_position"]) for r in rows] == [
            ("queued", 1), ("queued", 2)
        ]
        assert summarizer_worker._pop() == "d1"
        summarizer_worker._mark_dequeued(db, "d1")
        first = db.execute("SELECT summary_status, summary_queue_position FROM dumps WHERE id='d1'").fetchone()
        second = db.execute("SELECT summary_status, summary_queue_position FROM dumps WHERE id='d2'").fetchone()
        assert tuple(first) == ("running", None)
        assert tuple(second) == ("queued", 1)

        before = db.execute("SELECT COUNT(*) FROM change_log WHERE entity_id='d1'").fetchone()[0]
        assert summarizer_worker.summarize_dump(
            db, "d1", infer=lambda *_: (_ for _ in ()).throw(RuntimeError("boom\nrest"))
        ) is False
        failed = db.execute(
            "SELECT summary_status, summary_error, summary_queue_position FROM dumps WHERE id='d1'"
        ).fetchone()
        after = db.execute("SELECT COUNT(*) FROM change_log WHERE entity_id='d1'").fetchone()[0]
        assert tuple(failed) == ("failed", "RuntimeError: boom", None)
        assert after == before + 1

        assert summarizer_worker.summarize_dump(db, "d1", infer=lambda *_: "done", now=9)
        cleared = db.execute(
            "SELECT summary, summary_status, summary_error, summary_queue_position FROM dumps WHERE id='d1'"
        ).fetchone()
        assert tuple(cleared) == ("done", None, None, None)
    finally:
        summarizer_worker._reset_for_tests()
        db.close()


def test_device_push_cannot_overwrite_server_authored_five(temp_data_dir):
    init_db(str(temp_data_dir))
    db = sqlite3.connect(temp_data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    _insert_dump(db, "d")
    db.execute(
        "UPDATE dumps SET language='es', translated=1, summary_status='failed', "
        "summary_error='RuntimeError: x', summary_queue_position=7 WHERE id='d'"
    )
    change = SyncChange(
        entity_type="dump", entity_id="d", op="upsert", device_id="device-a",
        payload={
            "title": "Edited", "language": "fr", "translated": False,
            "summary_status": "queued", "summary_error": None,
            "summary_queue_position": 1,
        },
    )
    _apply_dump(db, change, 10)
    row = db.execute(
        "SELECT language, translated, summary_status, summary_error, summary_queue_position "
        "FROM dumps WHERE id='d'"
    ).fetchone()
    db.close()
    assert tuple(row) == ("es", 1, "failed", "RuntimeError: x", 7)
