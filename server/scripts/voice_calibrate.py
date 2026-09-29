# SPDX-License-Identifier: AGPL-3.0-or-later
"""Rank diarized speakers against a named reference for threshold calibration."""
from __future__ import annotations

import argparse
import json
import sqlite3
from collections.abc import Sequence
from pathlib import Path

from app.services.diarization import diarize_segments_with_embeddings
from app.services.voice_book import normalise


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b, strict=True))


def rank_against(
    reference: list[float],
    candidates: list[tuple[str, str, list[float]]],
) -> list[tuple[float, str, str]]:
    """Return ``(similarity, title, label)`` rows sorted best-first."""
    ref = normalise(reference)
    ranked = [
        (_dot(ref, normalise(embedding)), title, label)
        for title, label, embedding in candidates
    ]
    return sorted(ranked, key=lambda row: (-row[0], row[1], row[2]))


def _json_object(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _mean_centroid(vectors: list[list[float]]) -> list[float]:
    if not vectors:
        return []
    size = len(vectors[0])
    if any(len(vector) != size for vector in vectors):
        raise ValueError("reference embeddings have inconsistent dimensions")
    return normalise(
        [sum(float(vector[i]) for vector in vectors) / len(vectors) for i in range(size)]
    )


def calibrate(db_path: Path, audio_root: Path, name: str) -> None:
    """Re-diarize retained audio, persist missing centroids, and print ranking."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT id, title, transcript_timings, speaker_names, speaker_embeddings "
            "FROM dumps WHERE audio_kept = 1 AND deleted_at IS NULL ORDER BY created_at"
        ).fetchall()
        audio_by_stem = {
            path.stem: path
            for path in audio_root.iterdir()
            if path.is_file()
        } if audio_root.is_dir() else {}

        recordings: list[tuple[sqlite3.Row, dict[str, list[float]], dict[str, str]]] = []
        for row in rows:
            audio = audio_by_stem.get(row["id"])
            timings = _json_object(row["transcript_timings"])
            segments = timings.get("segments")
            if audio is None or not isinstance(segments, list):
                continue
            _labelled, embeddings = diarize_segments_with_embeddings(str(audio), segments)
            if not embeddings:
                continue
            if row["speaker_embeddings"] is None:
                conn.execute(
                    "UPDATE dumps SET speaker_embeddings = ? WHERE id = ?",
                    (json.dumps(embeddings), row["id"]),
                )
            recordings.append((row, embeddings, _json_object(row["speaker_names"])))
        conn.commit()

        references: list[list[float]] = []
        teaching_recordings: set[str] = set()
        candidates: list[tuple[str, str, list[float]]] = []
        already_named: dict[tuple[str, str], str] = {}
        for row, embeddings, names in recordings:
            title = row["title"] or row["id"]
            for label, embedding in embeddings.items():
                candidates.append((title, label, embedding))
                already_named[(title, label)] = names.get(label, "-")
                if names.get(label) == name:
                    references.append(embedding)
                    teaching_recordings.add(row["id"])

        reference = _mean_centroid(references)
        if not reference:
            raise SystemExit(f"no diarized label currently named {name!r}")

        print(
            f"reference {name!r} from {len(teaching_recordings)} recording(s), "
            f"{len(references)} label(s)"
        )
        print(" sim    recording                          label       already named")
        for similarity, title, label in rank_against(reference, candidates):
            print(
                f" {similarity:0.2f}   {title[:34]:34} {label:11} "
                f"{already_named[(title, label)]}"
            )
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="Jeff")
    parser.add_argument("--db", type=Path, default=Path("/data/tangent.db"))
    parser.add_argument("--audio-root", type=Path, default=Path("/data/audio"))
    args = parser.parse_args()
    calibrate(args.db, args.audio_root, args.name)


if __name__ == "__main__":
    main()
