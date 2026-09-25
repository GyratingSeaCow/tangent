# SPDX-License-Identifier: AGPL-3.0-or-later
"""Disk-space and path helpers."""

from __future__ import annotations

import os
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import sqlite3

_DB_SUFFIXES = {".db", ".db-journal", ".db-wal", ".db-shm"}

# Directories that are reinstallable machinery, not user storage, and are
# therefore never reported and never walked.
#
# The OCR environment (handwriting search) is ~29,000 files / 9.4 GB of venv.
# Walking it measured 74 s on a real install, which blew past the client's
# 60 s receive timeout: EVERY authenticated /v1/server/info hung, the app
# reported "server unreachable", and sync stopped entirely.
#
# These names are PRUNED (never descended), not merely filtered out of the
# sum: statting 29k files and discarding the numbers is just as slow.
#
# Matched only at the TOP LEVEL of data_dir, where the server creates them.
# A bare name test would also skip a user directory that happened to be
# called "ocr-env" at any depth, silently under-reporting real storage.
#
# The summarizer env (AI summaries: llama.cpp venv + ~2.5 GB GGUF) follows
# the same rule, added in the SAME commit that creates the env — the OCR
# arc shipped the walk-the-env bug and this list is where it was fixed.
_SKIP_DIRS = {"ocr-env", "ocr-env.tmp", "summarizer-env", "summarizer-env.tmp"}


def get_storage_used_bytes(data_dir: str) -> int:
    """Recursively sum file sizes under data_dir.

    Excludes the database files themselves and prunes reinstallable
    machinery (see ``_SKIP_DIRS``) so the walk stays fast enough to serve a
    request.
    """
    root = Path(data_dir)
    if not root.exists():
        return 0
    root_path = os.path.normpath(str(root))
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune in place: os.walk will not descend into what we remove here.
        # Only at the root, so nested user content keeps being counted.
        if os.path.normpath(dirpath) == root_path:
            dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS]
        for name in filenames:
            if Path(name).suffix in _DB_SUFFIXES:
                continue
            try:
                total += os.stat(os.path.join(dirpath, name)).st_size
            except OSError:
                # A file vanishing mid-walk (log rotation, cleanup) is not a
                # reason to fail the whole request.
                continue
    return total


SUPPORTED_MODELS = ("tiny", "base", "small", "medium", "large-v3")

#: Accuracy order, most accurate first. The client renders the picker in
#: exactly this order (Jeff's accuracy-first copy rule), so it lives beside
#: SUPPORTED_MODELS rather than being re-derived per caller.
MODELS_BY_ACCURACY = ("large-v3", "medium", "small", "base", "tiny")

#: The fallback when neither a persisted selection nor the env names a
#: supported model. Matches Settings.whisper_model's own default.
DEFAULT_MODEL = "large-v3"

#: app_settings key holding the user's model selection. A selection made
#: from ANY device changes what the SERVER transcribes with, so it belongs
#: in the server's settings table (summarizer_worker.SETTINGS_KEY precedent).
MODEL_SETTINGS_KEY = "whisper_model"


def is_supported_model(name: str) -> bool:
    return name in SUPPORTED_MODELS


def resolve_active_model(db: sqlite3.Connection | None) -> str:
    """The model this server should transcribe with, right now.

    Resolution order (requirement 1 of the model-selection spec):

    1. ``app_settings['whisper_model']`` when it names a SUPPORTED model —
       the user's explicit choice, made from any paired device;
    2. ``settings.whisper_model`` (``TANGENT_WHISPER_MODEL``) when supported —
       the operator's container default;
    3. ``DEFAULT_MODEL``.

    An unsupported value at either layer falls THROUGH rather than raising: a
    stale or hand-edited row must never leave the server unable to
    transcribe. ``db`` may be None (a load racing first-run init).
    """
    if db is not None:
        try:
            row = db.execute(
                "SELECT value FROM app_settings WHERE key = ?", (MODEL_SETTINGS_KEY,)
            ).fetchone()
        except Exception:
            # The table not existing yet (pre-init boot) is not a reason to
            # fail a transcription; fall through to the env default.
            row = None
        if row is not None:
            value = row[0]
            if is_supported_model(value):
                return value

    from app.config import get_settings

    env_choice = get_settings().whisper_model
    return env_choice if is_supported_model(env_choice) else DEFAULT_MODEL


def set_active_model(db: sqlite3.Connection, name: str) -> None:
    """Persist the active-model selection. Caller validates ``name``."""
    db.execute(
        "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
        (MODEL_SETTINGS_KEY, name),
    )
    db.commit()
