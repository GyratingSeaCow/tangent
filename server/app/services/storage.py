# SPDX-License-Identifier: AGPL-3.0-or-later
"""Disk-space and path helpers."""

from __future__ import annotations

from pathlib import Path


def get_storage_used_bytes(data_dir: str) -> int:
    """Recursively sum file sizes under data_dir. Excludes the .db file itself."""
    root = Path(data_dir)
    if not root.exists():
        return 0
    total = 0
    for path in root.rglob("*"):
        if path.is_file() and path.suffix not in {".db", ".db-journal", ".db-wal", ".db-shm"}:
            total += path.stat().st_size
    return total


SUPPORTED_MODELS = ("tiny", "base", "small", "medium", "large-v3")


def is_supported_model(name: str) -> bool:
    return name in SUPPORTED_MODELS