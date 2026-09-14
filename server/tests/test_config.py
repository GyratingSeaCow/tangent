# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for server config (model selection, env override)."""

from __future__ import annotations

import pytest

from app.config import Settings
from app.services.storage import SUPPORTED_MODELS


@pytest.fixture(autouse=True)
def _clear_settings_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    """Settings is @lru_cache-d; drop the cache between tests so env overrides stick."""
    from app import config

    config.get_settings.cache_clear()
    yield
    config.get_settings.cache_clear()


def test_default_model_is_large_v3() -> None:
    settings = Settings()
    assert settings.whisper_model == "large-v3"


def test_supported_models_includes_documented_set() -> None:
    # Regression guard: if you add/remove a model here, the README and
    # compose file must stay in sync.
    assert "tiny" in SUPPORTED_MODELS
    assert "base" in SUPPORTED_MODELS
    assert "small" in SUPPORTED_MODELS
    assert "medium" in SUPPORTED_MODELS
    assert "large-v3" in SUPPORTED_MODELS


def test_whisper_model_can_be_overridden_via_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_WHISPER_MODEL", "small")
    settings = Settings()
    assert settings.whisper_model == "small"


def test_data_dir_can_be_overridden_via_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DATA_DIR", "/srv/tangent")
    settings = Settings()
    assert settings.data_dir == "/srv/tangent"
