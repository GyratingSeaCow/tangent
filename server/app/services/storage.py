# SPDX-License-Identifier: AGPL-3.0-or-later
"""Disk-space and path helpers."""

from __future__ import annotations

import os
from pathlib import Path

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
_SKIP_DIRS = {"ocr-env", "ocr-env.tmp"}


def get_storage_used_bytes(data_dir: str) -> int:
    """Recursively sum file sizes under data_dir.

    Excludes the database files themselves and prunes reinstallable
    machinery (see ``_SKIP_DIRS``) so the walk stays fast enough to serve a
    request.
    """
    root = Path(data_dir)
    if not root.exists():
        return 0
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune in place: os.walk will not descend into what we remove here.
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


def is_supported_model(name: str) -> bool:
    return name in SUPPORTED_MODELS
