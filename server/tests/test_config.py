# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.config module."""

import pytest

from app.config import Settings


def test_settings_defaults():
    settings = Settings()
    assert settings.data_dir == "./data"
    assert settings.log_level == "info"
    assert settings.host == "0.0.0.0"
    assert settings.port == 8000
    assert settings.whisper_model == "large-v3"


def test_settings_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("TANGENT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TANGENT_LOG_LEVEL", "debug")
    monkeypatch.setenv("TANGENT_HOST", "127.0.0.1")
    monkeypatch.setenv("TANGENT_PORT", "9000")

    settings = Settings()
    assert settings.data_dir == str(tmp_path)
    assert settings.log_level == "debug"
    assert settings.host == "127.0.0.1"
    assert settings.port == 9000


def test_settings_data_dir_kept_as_default_string(tmp_path):
        settings = Settings(data_dir=str(tmp_path / "new_data"))
        assert settings.data_dir == str(tmp_path / "new_data")


def test_log_level_validation():
    with pytest.raises(ValueError):
        Settings(log_level="invalid")
