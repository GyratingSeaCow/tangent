# SPDX-License-Identifier: AGPL-3.0-or-later
"""Custom vocabulary storage, API, and transcription threading tests."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app import vocabulary
from app.db import init_db
from app.main import create_app
from app.services import job_queue, transcription
from app.services.transcription import TranscriptionResult, TranscriptionService


def test_normalize_splits_trims_dedupes_first_spelling_wins():
    assert vocabulary.normalize_vocabulary(" Hermes, CachyOS\nhermes\n Tangent,,") == [
        "Hermes",
        "CachyOS",
        "Tangent",
    ]
    assert vocabulary.normalize_vocabulary(" \n, ") == []


def test_normalize_rejects_a_65_character_term():
    with pytest.raises(vocabulary.VocabularyValidationError, match="^vocabulary term too long$"):
        vocabulary.normalize_vocabulary("x" * 65)


def test_normalize_rejects_201_terms():
    with pytest.raises(vocabulary.VocabularyValidationError, match="^too many vocabulary terms$"):
        vocabulary.normalize_vocabulary(",".join(f"term-{i}" for i in range(201)))


def test_hotwords_and_summary_suffix_empty_and_populated():
    assert vocabulary.hotwords_for([]) is None
    assert vocabulary.hotwords_for(["Hermes", "CachyOS"]) == "Hermes, CachyOS"
    assert vocabulary.summary_suffix([]) == ""
    assert vocabulary.summary_suffix(["Hermes", "CachyOS"]) == (
        "\n\nPreferred spellings for names and terms that may appear in the\n"
        "transcript: Hermes, CachyOS. Use these spellings exactly."
    )


@pytest.fixture
def api_client(temp_data_dir: Path):
    transcription.reset_transcription_service()
    with TestClient(create_app()) as client:
        token = client.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield client, {"Authorization": f"Bearer {token}"}, temp_data_dir
    transcription.reset_transcription_service()


def test_vocabulary_get_empty_put_round_trip_and_blank_clear(api_client):
    client, auth, data_dir = api_client
    empty = client.get("/v1/transcription/vocabulary", headers=auth)
    assert empty.status_code == 200
    assert empty.json() == {
        "terms": [],
        "text": "",
        "token_estimate": 0,
        "over_budget": False,
    }

    saved = client.put(
        "/v1/transcription/vocabulary", json={"text": "b\n a,b"}, headers=auth
    )
    assert saved.status_code == 200
    assert saved.json()["terms"] == ["b", "a"]
    assert saved.json()["text"] == "b, a"
    assert client.get("/v1/transcription/vocabulary", headers=auth).json() == saved.json()

    cleared = client.put(
        "/v1/transcription/vocabulary", json={"text": " \n, "}, headers=auth
    )
    assert cleared.status_code == 200
    assert cleared.json()["terms"] == []
    db = sqlite3.connect(data_dir / "tangent.db")
    try:
        assert db.execute(
            "SELECT value FROM app_settings WHERE key = 'custom_vocabulary'"
        ).fetchone() is None
    finally:
        db.close()


def test_vocabulary_api_validation_and_auth(api_client):
    client, auth, _ = api_client
    too_long = client.put(
        "/v1/transcription/vocabulary", json={"text": "x" * 65}, headers=auth
    )
    assert too_long.status_code == 422
    assert too_long.json()["detail"] == "vocabulary term too long"
    too_many = client.put(
        "/v1/transcription/vocabulary",
        json={"text": ",".join(f"t{i}" for i in range(201))},
        headers=auth,
    )
    assert too_many.status_code == 422
    assert too_many.json()["detail"] == "too many vocabulary terms"
    assert client.get("/v1/transcription/vocabulary").status_code == 401
    assert client.put("/v1/transcription/vocabulary", json={"text": "x"}).status_code == 401


def test_vocabulary_response_uses_loaded_tokenizer(api_client):
    client, auth, _ = api_client

    class Tokenizer:
        def encode(self, _text):
            return list(range(224))

    transcription._service = TranscriptionService("tiny")
    transcription._service._model = SimpleNamespace(hf_tokenizer=Tokenizer())
    body = client.put(
        "/v1/transcription/vocabulary", json={"text": "Hermes"}, headers=auth
    ).json()
    assert body["token_estimate"] == 224
    assert body["over_budget"] is True


class _RecordingService:
    def __init__(self):
        self.calls: list[tuple[str, str | None]] = []

    def transcribe(self, audio_path: str, *, hotwords: str | None = None):
        self.calls.append((audio_path, hotwords))
        return TranscriptionResult(text="done")


def _queued_job(data_dir: Path, job_id: str = "job-vocab") -> tuple[sqlite3.Connection, Path]:
    init_db(str(data_dir))
    db = sqlite3.connect(data_dir / "tangent.db")
    db.row_factory = sqlite3.Row
    db.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, audio_kept) "
        "VALUES ('dump-vocab', 'single-user', 1, 1, 'brain_dump', 1, 'T', 0)"
    )
    db.execute(
        "INSERT INTO jobs (id, request_id, dump_id, status, model) "
        "VALUES (?, 'request-vocab', 'dump-vocab', 'queued', 'large-v3')",
        (job_id,),
    )
    db.commit()
    audio = data_dir / "audio.wav"
    audio.write_bytes(b"RIFF")
    return db, audio


@pytest.mark.parametrize(
    ("saved", "expected"),
    [("Hermes, CachyOS", "Hermes, CachyOS"), (None, None)],
)
def test_run_job_inline_passes_current_hotwords(temp_data_dir, monkeypatch, saved, expected):
    db, audio = _queued_job(temp_data_dir)
    if saved is not None:
        vocabulary.set_vocabulary(db, saved)
    db.close()
    service = _RecordingService()
    monkeypatch.setattr(job_queue, "get_transcription_service", lambda: service)

    job_queue.run_job_inline("job-vocab", str(audio))

    assert service.calls == [(str(audio), expected)]


def test_vocabulary_edit_between_enqueue_and_run_uses_runtime_value(
    temp_data_dir, monkeypatch
):
    db, audio = _queued_job(temp_data_dir)
    vocabulary.set_vocabulary(db, "Old spelling")
    vocabulary.set_vocabulary(db, "Hermes, CachyOS")
    db.close()
    service = _RecordingService()
    monkeypatch.setattr(job_queue, "get_transcription_service", lambda: service)

    job_queue.run_job_inline("job-vocab", str(audio))

    assert service.calls == [(str(audio), "Hermes, CachyOS")]


def test_transcription_threads_hotwords_and_logs_count_not_terms(monkeypatch, tmp_path):
    calls: list[dict] = []
    events: list[tuple[str, dict]] = []

    class Model:
        def transcribe(self, _audio, **kwargs):
            calls.append(kwargs)
            return [], SimpleNamespace(language="en")

    class Log:
        def info(self, event, **kwargs):
            events.append((event, kwargs))

        def warning(self, *_args, **_kwargs):
            pass

    monkeypatch.setattr(transcription, "_decode_audio_samples", lambda _path: [0.0])
    monkeypatch.setattr(transcription, "log", Log())
    service = TranscriptionService("tiny")
    service._model = Model()
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")

    service.transcribe(str(audio), hotwords="Hermes, CachyOS")

    assert calls[0]["hotwords"] == "Hermes, CachyOS"
    start = next(data for event, data in events if event == "transcription.start")
    assert start["hotword_terms"] == 2
    assert "Hermes" not in repr(start)
