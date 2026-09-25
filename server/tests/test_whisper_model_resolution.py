# SPDX-License-Identifier: AGPL-3.0-or-later
"""Requirement 1: a persisted selection overrides the env default.

Resolution order is ``app_settings.whisper_model`` (when supported) →
``settings.whisper_model`` (TANGENT_WHISPER_MODEL) → ``large-v3``, and
``TranscriptionService`` must resolve THROUGH that helper at load time
rather than reading config directly — otherwise a selection made through
the API would need a container restart to take effect.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from app.db import init_db
from app.services import transcription
from app.services.storage import (
    DEFAULT_MODEL,
    MODEL_SETTINGS_KEY,
    resolve_active_model,
    set_active_model,
)


@pytest.fixture
def db(temp_data_dir: Path) -> sqlite3.Connection:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    yield conn
    conn.close()


@pytest.fixture(autouse=True)
def _no_env_model(monkeypatch: pytest.MonkeyPatch):
    """Each test states its own env arm; inherit nothing from the shell."""
    monkeypatch.delenv("TANGENT_WHISPER_MODEL", raising=False)
    yield


class FakeWhisperModel:
    """Stand-in for faster_whisper.WhisperModel (no weights, no download)."""

    def __init__(self, model_name: str, **kwargs):
        self.model_name = model_name
        self.kwargs = kwargs


# ---------------------------------------------------------------------------
# resolve_active_model: the three arms, in order
# ---------------------------------------------------------------------------


class TestResolutionOrder:
    def test_persisted_selection_wins_over_env(self, db, monkeypatch):
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "medium")
        set_active_model(db, "small")
        assert resolve_active_model(db) == "small"

    def test_env_is_used_when_nothing_is_persisted(self, db, monkeypatch):
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "medium")
        assert resolve_active_model(db) == "medium"

    def test_unsupported_persisted_value_falls_through_to_env(self, db, monkeypatch):
        """A hand-edited / stale settings row must never strand the server on
        a model faster-whisper cannot load."""
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "base")
        db.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
            (MODEL_SETTINGS_KEY, "definitely-not-a-model"),
        )
        db.commit()
        assert resolve_active_model(db) == "base"

    def test_unsupported_env_falls_through_to_the_default(self, db, monkeypatch):
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "whisper-9000")
        assert resolve_active_model(db) == DEFAULT_MODEL
        assert DEFAULT_MODEL == "large-v3"

    def test_no_db_resolves_to_env_without_raising(self, temp_data_dir, monkeypatch):
        """A load happening before the database exists must degrade to the env
        default, not fail the transcription."""
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "tiny")
        assert resolve_active_model(None) == "tiny"

    def test_set_active_model_persists_under_the_documented_key(self, db):
        set_active_model(db, "base")
        row = db.execute(
            "SELECT value FROM app_settings WHERE key = ?", (MODEL_SETTINGS_KEY,)
        ).fetchone()
        assert row["value"] == "base"
        assert MODEL_SETTINGS_KEY == "whisper_model"

    def test_set_active_model_replaces_a_previous_selection(self, db):
        set_active_model(db, "base")
        set_active_model(db, "tiny")
        rows = db.execute(
            "SELECT value FROM app_settings WHERE key = ?", (MODEL_SETTINGS_KEY,)
        ).fetchall()
        assert [r["value"] for r in rows] == ["tiny"]


# ---------------------------------------------------------------------------
# TranscriptionService resolves through the helper at LOAD time
# ---------------------------------------------------------------------------


class TestServiceResolvesAtLoadTime:
    def test_load_uses_the_persisted_selection_not_the_env(
        self, db, temp_data_dir, monkeypatch
    ):
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "large-v3")
        monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)
        set_active_model(db, "tiny")

        service = transcription.TranscriptionService()
        service.load_model()

        assert service.model_name == "tiny"
        assert service._model.model_name == "tiny"

    def test_a_selection_made_after_construction_is_picked_up_at_load(
        self, db, temp_data_dir, monkeypatch
    ):
        """The service must NOT snapshot the model in __init__: the API
        writes app_settings and drops the cached instance, and the next load
        has to see the new value."""
        monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)
        service = transcription.TranscriptionService()
        set_active_model(db, "base")

        service.load_model()

        assert service._model.model_name == "base"

    def test_an_explicit_model_name_is_pinned_and_ignores_the_selection(
        self, db, temp_data_dir, monkeypatch
    ):
        """/v1/models/{name}/pull and the tests name a model explicitly; that
        must keep overriding whatever is selected."""
        monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)
        set_active_model(db, "tiny")

        service = transcription.TranscriptionService(model_name="large-v3")
        service.load_model()

        assert service._model.model_name == "large-v3"

    def test_resolve_configured_model_does_not_create_a_database(
        self, temp_data_dir, monkeypatch
    ):
        """Resolution must never have the side effect of creating the db —
        a model load on a fresh container would otherwise race init_db."""
        monkeypatch.setenv("TANGENT_WHISPER_MODEL", "small")
        assert not (temp_data_dir / "tangent.db").exists()

        assert transcription.resolve_configured_model() == "small"

        assert not (temp_data_dir / "tangent.db").exists()
