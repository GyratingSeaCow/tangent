# SPDX-License-Identifier: AGPL-3.0-or-later
"""Geometric ink segmentation: strokes -> Lines of Words. Pure geometry, no ML.

Line clustering uses y-CENTRE gaps (proven in the Task 0 bake-off on real
handwriting): descenders (g, y) overlap the next line's top edge, so
bottom-edge or interval-overlap tracking merges real lines into blobs.
Centres of same-line strokes cluster tightly even when their boxes overlap
across lines. Word splitting follows the plan brief: sort by x-centre and
split where the horizontal gap exceeds 0.6*H (H = median pen-stroke bbox
height); overlapping boxes merge naturally (i-dots and t-crosses ride along).
"""

from __future__ import annotations

import hashlib
import statistics
from dataclasses import dataclass, field


@dataclass
class Word:
    stroke_ids: list[str] = field(default_factory=list)
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)


@dataclass
class Line:
    line_id: str
    words: list[Word] = field(default_factory=list)


def _stroke_bbox(s: dict) -> tuple[float, float, float, float]:
    xs = [p["x"] for p in s["points"]]
    ys = [p["y"] for p in s["points"]]
    return min(xs), min(ys), max(xs), max(ys)


def _median_height(pen: list[dict]) -> float:
    heights = [_stroke_bbox(s)[3] - _stroke_bbox(s)[1] for s in pen]
    return statistics.median([h for h in heights if h > 1] or [20.0])


def _cluster_lines(pen: list[dict], h: float) -> list[list[dict]]:
    """Group strokes into lines by bbox y-centre gaps (see module docstring)."""

    def centre(s: dict) -> float:
        b = _stroke_bbox(s)
        return (b[1] + b[3]) / 2

    ordered = sorted(pen, key=lambda s: (centre(s), s.get("id", "")))
    lines: list[list[dict]] = [[ordered[0]]]
    for s in ordered[1:]:
        line_centre = statistics.median(centre(t) for t in lines[-1])
        if centre(s) - line_centre > 0.9 * h:
            lines.append([s])
        else:
            lines[-1].append(s)
    return lines


def _split_words(line: list[dict], h: float) -> list[Word]:
    """Split a line's strokes into Words at horizontal gaps > 0.6*H.

    Strokes are sorted by bbox x-centre; a running max right edge merges
    overlapping boxes so i-dots and t-crosses stay with their word.
    """

    def x_centre(s: dict) -> float:
        b = _stroke_bbox(s)
        return (b[0] + b[2]) / 2

    ordered = sorted(line, key=lambda s: (x_centre(s), s.get("id", "")))
    clusters: list[list[dict]] = [[ordered[0]]]
    right = _stroke_bbox(ordered[0])[2]
    for s in ordered[1:]:
        b = _stroke_bbox(s)
        if b[0] - right > 0.6 * h:
            clusters.append([s])
        else:
            clusters[-1].append(s)
        right = max(right, b[2])

    words = []
    for cluster in clusters:
        boxes = [_stroke_bbox(s) for s in cluster]
        bbox = (
            min(b[0] for b in boxes),
            min(b[1] for b in boxes),
            max(b[2] for b in boxes),
            max(b[3] for b in boxes),
        )
        ids = [s["id"] for s in sorted(cluster, key=lambda s: (x_centre(s), s.get("id", "")))]
        words.append(Word(stroke_ids=ids, bbox=bbox))
    return words


def _line_id(words: list[Word]) -> str:
    ids = sorted(sid for w in words for sid in w.stroke_ids)
    return hashlib.sha1(",".join(ids).encode("utf-8")).hexdigest()


def segment_ink(strokes: list[dict]) -> list[Line]:
    """Cluster pen strokes into Lines of Words, top-to-bottom, left-to-right.

    Highlighter strokes are emphasis, not writing: excluded. Strokes with no
    points are skipped. ``line_id`` is the sha1 of the line's sorted member
    stroke ids — deterministic across re-runs and stroke order, so it is a
    stable cache/invalidation key.
    """
    pen = [s for s in strokes if s.get("tool", "pen") == "pen" and s.get("points")]
    if not pen:
        return []
    h = _median_height(pen)
    return [
        Line(line_id=_line_id(words), words=words)
        for cluster in _cluster_lines(pen, h)
        for words in [_split_words(cluster, h)]
    ]
