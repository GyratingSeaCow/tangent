# SPDX-License-Identifier: AGPL-3.0-or-later
"""Shared pytest fixtures."""

from __future__ import annotations

import os
from collections.abc import Generator
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _reset_settings_cache():
    """Clear the lru_cache on get_settings() so each test gets a fresh Settings."""
    from app.config import get_settings

    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def temp_data_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Generator[Path, None, None]:
    """Provide a temporary data dir, set as TANGENT_DATA_DIR."""
    data_dir = tmp_path / "tangent_data"
    data_dir.mkdir()
    monkeypatch.setenv("TANGENT_DATA_DIR", str(data_dir))
    yield data_dir


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch) -> Generator[None, None, None]:
    """Strip all TANGENT_* env vars so tests get defaults."""
    for key in list(os.environ):
        if key.startswith("TANGENT_"):
            monkeypatch.delenv(key)
    yield
