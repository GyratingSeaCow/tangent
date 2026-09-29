# SPDX-License-Identifier: AGPL-3.0-or-later
"""Voice book: teach math, matching rules, forget. Pure sqlite, no pyannote."""
from __future__ import annotations

import math
import sqlite3
from pathlib import Path

import pytest

from app.db import init_db
from app.services import voice_book as vb


def _unit(*coords: float) -> list[float]:
    n = math.sqrt(sum(c * c for c in coords))
    return [c / n for c in coords]


@pytest.fixture
def conn(temp_data_dir: Path) -> sqlite3.Connection:
    init_db(str(temp_data_dir))
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    c.row_factory = sqlite3.Row
    return c


def test_schema_has_voice_book_and_embeddings_column(conn):
    cols = {r[1] for r in conn.execute("PRAGMA table_info(voice_book)")}
    assert cols == {"name", "embedding", "samples", "updated_at"}
    dump_cols = {r[1] for r in conn.execute("PRAGMA table_info(dumps)")}
    assert "speaker_embeddings" in dump_cols


def test_migration_is_idempotent(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))
    c = sqlite3.connect(temp_data_dir / "tangent.db")
    assert c.execute("SELECT count(*) FROM voice_book").fetchone()[0] == 0


def test_normalise_unit_and_zero():
    assert vb.normalise([3.0, 4.0]) == pytest.approx([0.6, 0.8])
    assert vb.normalise([0.0, 0.0]) == [0.0, 0.0]


def test_teach_first_sample_is_the_embedding_normalised(conn):
    vb.teach(conn, "Jeff", [3.0, 4.0], now="2026-09-29T00:00:00Z")
    row = conn.execute("SELECT * FROM voice_book WHERE name = 'Jeff'").fetchone()
    assert row["samples"] == 1
    assert vb.load_voice_book(conn)[0].embedding == pytest.approx([0.6, 0.8])
    assert row["updated_at"] == "2026-09-29T00:00:00Z"


def test_teach_running_mean_renormalised(conn):
    vb.teach(conn, "Jeff", _unit(1, 0))
    vb.teach(conn, "Jeff", _unit(0, 1))
    entry = vb.load_voice_book(conn)[0]
    assert entry.samples == 2
    assert entry.embedding == pytest.approx(_unit(1, 1))
    vb.teach(conn, "Jeff", _unit(1, 0))
    entry = vb.load_voice_book(conn)[0]
    assert entry.samples == 3
    # The specified update weights the stored, normalised centroid by samples.
    prior = _unit(1, 1)
    expected = vb.normalise([(prior[0] * 2 + 1) / 3, prior[1] * 2 / 3])
    assert entry.embedding == pytest.approx(expected)


def test_teach_is_case_sensitive_and_trims(conn):
    vb.teach(conn, "  Jeff ", _unit(1, 0))
    vb.teach(conn, "jeff", _unit(0, 1))
    names = sorted(e.name for e in vb.load_voice_book(conn))
    assert names == ["Jeff", "jeff"]


def test_teach_rejects_empty_name(conn):
    with pytest.raises(ValueError):
        vb.teach(conn, "   ", _unit(1, 0))


def _book(**names: list[float]) -> list[vb.VoiceEntry]:
    return [vb.VoiceEntry(n, vb.normalise(e), 1, "t") for n, e in names.items()]


def test_match_accepts_above_threshold_with_margin():
    book = _book(Jeff=_unit(1, 0), Tom=_unit(0, 1))
    names, rejected = vb.match(
        {"Speaker 1": _unit(0.95, 0.05), "Speaker 2": _unit(0.1, 0.9)},
        book, accept=0.70, margin=0.10,
    )
    assert names == {"Speaker 1": "Jeff", "Speaker 2": "Tom"}
    assert rejected == []


def test_match_rejects_below_accept():
    book = _book(Jeff=_unit(1, 0))
    names, rejected = vb.match({"Speaker 1": _unit(0.6, 0.8)}, book, accept=0.70, margin=0.10)
    assert names == {}
    assert rejected == [("Speaker 1", pytest.approx(0.6), "Jeff")]


def test_match_rejects_when_margin_too_small():
    book = _book(Jeff=_unit(1, 0.9), Tom=_unit(0.9, 1))
    names, rejected = vb.match({"Speaker 1": _unit(1, 1)}, book, accept=0.70, margin=0.10)
    assert names == {}
    assert rejected[0][0] == "Speaker 1"


def test_match_single_name_book_has_no_margin_penalty():
    book = _book(Jeff=_unit(1, 0))
    names, _ = vb.match({"Speaker 1": _unit(1, 0.1)}, book, accept=0.70, margin=0.10)
    assert names == {"Speaker 1": "Jeff"}


def test_match_one_label_per_name_higher_similarity_wins():
    book = _book(Jeff=_unit(1, 0))
    names, rejected = vb.match(
        {"Speaker 1": _unit(1, 0.3), "Speaker 2": _unit(1, 0.1)},
        book, accept=0.70, margin=0.10,
    )
    assert names == {"Speaker 2": "Jeff"}
    assert [r[0] for r in rejected] == ["Speaker 1"]


def test_match_empty_book_or_no_embeddings():
    assert vb.match({"Speaker 1": _unit(1, 0)}, [], accept=0.7, margin=0.1) == ({}, [])
    assert vb.match({}, _book(Jeff=_unit(1, 0)), accept=0.7, margin=0.1) == ({}, [])


def test_forget_removes_exactly_one_row(conn):
    vb.teach(conn, "Jeff", _unit(1, 0))
    vb.teach(conn, "Tom", _unit(0, 1))
    assert vb.forget(conn, "Tom") is True
    assert vb.forget(conn, "Tom") is False
    assert [e.name for e in vb.load_voice_book(conn)] == ["Jeff"]


def test_nan_embedding_is_rejected_by_teach_and_skipped_by_match(conn):
    """pyannote returns NaN centroids for near-empty recordings; they must
    never enter the book or produce a match (calibration 2026-09-29)."""
    nan = [float("nan")] * 2
    assert vb.is_finite(nan) is False and vb.is_finite([]) is False
    assert vb.is_finite([0.0, 1.0]) is True
    with pytest.raises(ValueError):
        vb.teach(conn, "Ghost", nan)
    assert vb.load_voice_book(conn) == []
    book = _book(Jeff=_unit(1, 0))
    names, rejected = vb.match({"Speaker 1": nan}, book, accept=0.7, margin=0.1)
    assert names == {}
