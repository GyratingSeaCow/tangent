# SPDX-License-Identifier: AGPL-3.0-or-later
"""Geometric ink segmentation: strokes -> Lines of Words (no ML)."""

from __future__ import annotations

import json
import random
from pathlib import Path

from app.services.ink_segmentation import Line, Word, segment_ink

FIXTURES = Path(__file__).parent / "fixtures"


def _stroke(sid: str, points: list[tuple[float, float]], *, tool: str = "pen",
            width: float = 3.0) -> dict:
    return {
        "id": sid,
        "width": width,
        "tool": tool,
        "points": [{"x": float(x), "y": float(y)} for x, y in points],
    }


def _word_at(x: float, *, y: float = 0.0, prefix: str | None = None) -> list[dict]:
    """A synthetic multi-stroke 'word': three ~40-high strokes close together.

    Strokes are 20 wide with 5px gaps between them (well under 0.6*H = 24),
    so they cluster into one Word.
    """
    prefix = prefix if prefix is not None else f"w{x:g}-{y:g}"
    strokes = []
    for i in range(3):
        sx = x + i * 25.0
        strokes.append(
            _stroke(
                f"{prefix}-s{i}",
                [(sx, y), (sx + 20.0, y + 40.0), (sx + 10.0, y + 20.0)],
            )
        )
    return strokes


def test_word_gap_splits_words():
    strokes = _word_at(x=0) + _word_at(x=200)   # helpers build multi-stroke words, height ~40
    lines = segment_ink(strokes)
    assert len(lines) == 1 and len(lines[0].words) == 2
    # Left-to-right promise: words[0] is the x=0 word, not merely "a" word.
    assert lines[0].words[0].stroke_ids == ["w0-0-s0", "w0-0-s1", "w0-0-s2"]
    assert lines[0].words[0].bbox[0] < lines[0].words[1].bbox[0]


def test_two_lines_at_distinct_y_bands():
    strokes = _word_at(x=0, y=0) + _word_at(x=0, y=100, prefix="lower")
    lines = segment_ink(strokes)
    assert len(lines) == 2
    for line in lines:
        assert len(line.words) == 1


def test_lines_ordered_top_to_bottom():
    """Docstring promise: lines come back in ascending y (reading order)."""
    strokes = (
        _word_at(x=0, y=0, prefix="top")
        + _word_at(x=0, y=100, prefix="mid")
        + _word_at(x=0, y=200, prefix="bot")
    )
    # Feed strokes bottom-first so input order can't accidentally satisfy this.
    lines = segment_ink(list(reversed(strokes)))
    assert len(lines) == 3
    first_ids = [sid for w in lines[0].words for sid in w.stroke_ids]
    assert set(first_ids) == {"top-s0", "top-s1", "top-s2"}
    tops = [min(w.bbox[1] for w in line.words) for line in lines]
    assert tops == sorted(tops), f"lines not in ascending y: {tops}"


def test_highlighter_excluded_from_words():
    strokes = _word_at(x=0)
    strokes.append(
        _stroke("hl-1", [(-5, -5), (80, 45)], tool="highlighter", width=12.0)
    )
    lines = segment_ink(strokes)
    all_ids = [sid for line in lines for w in line.words for sid in w.stroke_ids]
    assert "hl-1" not in all_ids
    assert sorted(all_ids) == sorted(s["id"] for s in strokes if s["tool"] == "pen")


def test_single_dot_stroke_is_one_word():
    strokes = [_stroke("dot", [(10.0, 10.0)])]
    lines = segment_ink(strokes)
    assert len(lines) == 1
    assert len(lines[0].words) == 1
    assert lines[0].words[0].stroke_ids == ["dot"]


def test_line_id_stable_under_stroke_order():
    strokes = _word_at(x=0) + _word_at(x=200)
    a = segment_ink(strokes)
    b = segment_ink(list(reversed(strokes)))
    assert [l.line_id for l in a] == [l.line_id for l in b]


def test_line_id_stable_under_shuffle():
    strokes = _word_at(x=0) + _word_at(x=200) + _word_at(x=0, y=100)
    a = segment_ink(strokes)
    shuffled = list(strokes)
    random.Random(42).shuffle(shuffled)
    b = segment_ink(shuffled)
    assert [l.line_id for l in a] == [l.line_id for l in b]


def test_empty_points_strokes_skipped():
    strokes = _word_at(x=0)
    strokes.append({"id": "empty", "width": 3.0, "tool": "pen", "points": []})
    lines = segment_ink(strokes)
    all_ids = [sid for line in lines for w in line.words for sid in w.stroke_ids]
    assert "empty" not in all_ids
    assert len(lines) == 1


def test_no_strokes_gives_no_lines():
    assert segment_ink([]) == []


def test_word_bbox_covers_member_strokes():
    strokes = _word_at(x=0)
    lines = segment_ink(strokes)
    (word,) = lines[0].words
    x0, y0, x1, y1 = word.bbox
    assert x0 <= 0.0 and y0 <= 0.0
    assert x1 >= 70.0 and y1 >= 40.0


def test_real_handwriting_fixture_lines():
    """Regression: the Task 0 bake-off sample (real handwriting) is 4 lines."""
    data = json.loads((FIXTURES / "bakeoff_ink.json").read_text())
    lines = segment_ink(data["strokes"])
    assert len(lines) == 4
    covered = sum(len(w.stroke_ids) for line in lines for w in line.words)
    assert covered == 148  # every stroke lands in exactly one word
