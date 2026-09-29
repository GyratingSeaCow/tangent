# SPDX-License-Identifier: AGPL-3.0-or-later
"""The voice book: one remembered centroid per display name.

Pure math + sqlite. No HTTP, no pyannote — the diarization service hands
over ``{label: embedding}``, this module decides who they are.
"""
from __future__ import annotations

import json
import math
import sqlite3
from collections.abc import Mapping, Sequence
from datetime import datetime, timezone
from typing import NamedTuple

VOICE_DIM = 256


class VoiceEntry(NamedTuple):
    name: str
    embedding: list[float]
    samples: int
    updated_at: str


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_finite(v: Sequence[float]) -> bool:
    """False for an empty vector or any NaN/inf component. pyannote hands
    back NaN centroids for very short recordings; those must never be
    stored, taught or matched (calibration run 2026-09-29: ``nan`` rows)."""
    return len(v) > 0 and all(math.isfinite(float(x)) for x in v)


def normalise(v: Sequence[float]) -> list[float]:
    norm = math.sqrt(sum(float(x) * float(x) for x in v))
    if norm == 0.0 or not math.isfinite(norm):
        return [0.0 for _ in v]
    return [float(x) / norm for x in v]


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b, strict=True))


def teach(
    conn: sqlite3.Connection,
    name: str,
    embedding: Sequence[float],
    *,
    now: str | None = None,
) -> None:
    """Fold one centroid into ``name``'s running mean (re-normalised)."""
    clean = name.strip()
    if not clean:
        raise ValueError("voice name must not be empty")
    if not is_finite(embedding):
        raise ValueError("voice embedding must be finite and non-empty")
    incoming = normalise(embedding)
    stamp = now or _now()
    row = conn.execute(
        "SELECT embedding, samples FROM voice_book WHERE name = ?", (clean,)
    ).fetchone()
    if row is None:
        conn.execute(
            "INSERT INTO voice_book (name, embedding, samples, updated_at) "
            "VALUES (?, ?, 1, ?)",
            (clean, json.dumps(incoming), stamp),
        )
        return
    old = json.loads(row[0])
    n = int(row[1])
    mean = [(o * n + i) / (n + 1) for o, i in zip(old, incoming, strict=True)]
    conn.execute(
        "UPDATE voice_book SET embedding = ?, samples = ?, updated_at = ? "
        "WHERE name = ?",
        (json.dumps(normalise(mean)), n + 1, stamp, clean),
    )


def load_voice_book(conn: sqlite3.Connection) -> list[VoiceEntry]:
    return [
        VoiceEntry(r[0], json.loads(r[1]), int(r[2]), r[3])
        for r in conn.execute(
            "SELECT name, embedding, samples, updated_at FROM voice_book "
            "ORDER BY updated_at DESC, name"
        )
    ]


def forget(conn: sqlite3.Connection, name: str) -> bool:
    cur = conn.execute("DELETE FROM voice_book WHERE name = ?", (name.strip(),))
    return cur.rowcount == 1


def match(
    embeddings: Mapping[str, Sequence[float]],
    book: Sequence[VoiceEntry],
    *,
    accept: float,
    margin: float,
) -> tuple[dict[str, str], list[tuple[str, float, str]]]:
    """Return (label→name, rejected) — see the spec's §Matching.

    A label is named when its best similarity ≥ ``accept`` and beats the
    second-best NAME by ≥ ``margin`` (no penalty with a one-name book).
    Each name goes to at most one label: the higher similarity keeps it,
    the loser is reported as rejected.
    """
    if not embeddings or not book:
        return {}, []
    candidates: list[tuple[float, str, str]] = []
    rejected: list[tuple[str, float, str]] = []
    for label, emb in embeddings.items():
        e = normalise(emb)
        sims = sorted(
            ((_dot(e, b.embedding), b.name) for b in book), reverse=True
        )
        best, best_name = sims[0]
        second = sims[1][0] if len(sims) > 1 else -1.0
        if best >= accept and (best - second) >= margin:
            candidates.append((best, label, best_name))
        else:
            rejected.append((label, best, best_name))
    names: dict[str, str] = {}
    claimed: set[str] = set()
    for sim, label, name in sorted(candidates, reverse=True):
        if name in claimed:
            rejected.append((label, sim, name))
            continue
        claimed.add(name)
        names[label] = name
    return names, rejected
