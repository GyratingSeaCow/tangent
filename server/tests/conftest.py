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


@pytest.fixture(autouse=True)
def _reset_sse_app_status():
    """Drop sse-starlette's cached shutdown Event between tests.

    `AppStatus.should_exit_event` is a module-level singleton created on first
    use and never cleared. Each test runs in its own event loop, so the second
    SSE test to run inherits an Event bound to the first test's (closed) loop
    and dies with "is bound to a different event loop". This is only visible on
    sse-starlette 2.x — the version a fresh `pip install` resolves from our
    declared `<3` constraint — which is why the full suite could pass locally
    while failing for anyone installing from scratch.
    """
    try:
        from sse_starlette.sse import AppStatus
    except ImportError:  # pragma: no cover - sse-starlette always installed
        yield
        return

    AppStatus.should_exit_event = None
    yield
    AppStatus.should_exit_event = None


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
