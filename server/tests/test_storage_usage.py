# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for get_storage_used_bytes.

The OCR environment (handwriting search, v1.7.0) installs ~29,000 files and
9.4 GB into ``<data_dir>/ocr-env``. Walking it pushed /v1/server/info past
74 seconds on Jeff's live server, beyond the client's 60 s receive timeout:
every authenticated request hung, the app reported "server unreachable", and
sync stopped entirely. These tests pin that the walk skips the OCR env.
"""

from pathlib import Path

from app.services.storage import get_storage_used_bytes


def _write(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)


def test_counts_ordinary_files(tmp_path: Path):
    _write(tmp_path / "audio" / "a.m4a", 100)
    _write(tmp_path / "audio" / "b.m4a", 50)
    assert get_storage_used_bytes(str(tmp_path)) == 150


def test_excludes_database_files(tmp_path: Path):
    _write(tmp_path / "audio" / "a.m4a", 100)
    _write(tmp_path / "tangent.db", 999)
    _write(tmp_path / "tangent.db-wal", 999)
    _write(tmp_path / "tangent.db-shm", 999)
    _write(tmp_path / "tangent.db-journal", 999)
    assert get_storage_used_bytes(str(tmp_path)) == 100


def test_excludes_ocr_env(tmp_path: Path):
    """The installed OCR venv is reinstallable machinery, not user storage."""
    _write(tmp_path / "audio" / "a.m4a", 100)
    _write(tmp_path / "ocr-env" / "venv" / "lib" / "torch" / "big.so", 5000)
    _write(tmp_path / "ocr-env" / "marker.json", 20)
    assert get_storage_used_bytes(str(tmp_path)) == 100


def test_excludes_ocr_env_tmp(tmp_path: Path):
    """A half-finished install (atomic tmp dir) must not be walked either."""
    _write(tmp_path / "audio" / "a.m4a", 100)
    _write(tmp_path / "ocr-env.tmp" / "venv" / "lib" / "torch" / "big.so", 5000)
    assert get_storage_used_bytes(str(tmp_path)) == 100


def test_does_not_descend_into_ocr_env(tmp_path: Path):
    """Pruning, not filtering.

    Excluding by summing-then-skipping would still stat 29k files and keep the
    endpoint slow. Pin that the directory is never descended: a file buried
    deep under ocr-env must not be reachable by the walk. Guarded by counting
    how many paths the walk actually visits.
    """
    _write(tmp_path / "audio" / "a.m4a", 100)
    deep = tmp_path / "ocr-env"
    for i in range(50):
        _write(deep / f"pkg{i}" / f"mod{i}.py", 10)

    visited: list[str] = []
    real_scandir = __import__("os").scandir

    import os

    def counting_scandir(path):
        visited.append(str(path))
        return real_scandir(path)

    os.scandir = counting_scandir
    try:
        total = get_storage_used_bytes(str(tmp_path))
    finally:
        os.scandir = real_scandir

    assert total == 100
    assert not any("ocr-env" in v for v in visited), (
        f"walk descended into the OCR env: {[v for v in visited if 'ocr-env' in v]}"
    )


def test_missing_dir_is_zero(tmp_path: Path):
    assert get_storage_used_bytes(str(tmp_path / "nope")) == 0


def test_nested_ocr_env_is_still_counted(tmp_path):
    """Only the server's own top-level ocr-env is machinery.

    A directory that merely shares the name deeper in the tree is user
    content: skipping it by name at any depth would silently under-report
    storage with no way for the user to tell.
    """
    (tmp_path / "ocr-env").mkdir()
    (tmp_path / "ocr-env" / "big.bin").write_bytes(b"x" * 5000)

    nested = tmp_path / "audio" / "ocr-env"
    nested.mkdir(parents=True)
    (nested / "note.m4a").write_bytes(b"y" * 321)

    assert get_storage_used_bytes(str(tmp_path)) == 321
