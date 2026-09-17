# SPDX-License-Identifier: AGPL-3.0-or-later
"""Optional speaker diarization.

OFF by default. Enabled only when BOTH:
  * TANGENT_DIARIZATION=pyannote
  * HF_TOKEN=<a HuggingFace access token>

pyannote.audio is NOT a hard dependency: it is imported lazily inside
``_load_pipeline`` and every failure path degrades to ``speaker=None`` with a
logged warning. Speaker labels are never fabricated — if diarization did not
actually run and produce overlapping turns, the speaker stays None.
"""

from __future__ import annotations

import os
from typing import Any

from app.logging_config import get_logger

log = get_logger(__name__)

DIARIZATION_BACKEND = "pyannote"
PYANNOTE_PIPELINE = "pyannote/speaker-diarization-3.1"

# (start, end, raw_label) as reported by the diarization backend.
Turn = tuple[float, float, str]

_pipeline: Any | None = None


def is_diarization_enabled() -> bool:
    """True only when the env flag names the pyannote backend AND a token exists."""
    backend = os.environ.get("TANGENT_DIARIZATION", "").strip().lower()
    if backend != DIARIZATION_BACKEND:
        return False
    return bool(os.environ.get("HF_TOKEN", "").strip())


def _import_pipeline() -> Any:
    """Import pyannote lazily and return the Pipeline class.

    Isolated as a seam so tests can substitute a fake pyannote without the
    optional dependency installed, and so the ImportError surfaces from one
    well-known place.
    """
    from pyannote.audio import Pipeline  # noqa: PLC0415 -- optional dependency

    return Pipeline


def _load_pipeline() -> Any:
    """Import pyannote lazily and build (once) the diarization pipeline.

    Raises ImportError if the optional package is absent, or any pyannote error
    if the pipeline cannot be constructed. Callers must tolerate both.
    """
    global _pipeline
    if _pipeline is not None:
        return _pipeline

    pipeline_cls = _import_pipeline()

    token = os.environ.get("HF_TOKEN", "").strip()
    log.info("diarization.loading_pipeline", pipeline=PYANNOTE_PIPELINE)
    try:
        # pyannote >= 3.3 renamed the auth kwarg to `token`.
        pipeline = pipeline_cls.from_pretrained(PYANNOTE_PIPELINE, token=token)
    except TypeError:
        # pyannote 3.x only accepts `use_auth_token`.
        pipeline = pipeline_cls.from_pretrained(
            PYANNOTE_PIPELINE, use_auth_token=token
        )
    if pipeline is None:
        # pyannote returns None instead of raising when the token lacks
        # access to the gated model.
        raise RuntimeError(
            f"pyannote returned no pipeline for {PYANNOTE_PIPELINE!r} "
            "(token may not have accepted the model's terms)"
        )
    _pipeline = pipeline
    return _pipeline


def reset_pipeline() -> None:
    """Drop the cached pipeline. Useful for tests and config changes."""
    global _pipeline
    _pipeline = None


def _extract_turns(annotation: Any) -> list[Turn]:
    """Flatten a pyannote Annotation into (start, end, label) tuples."""
    turns: list[Turn] = []
    for segment, _track, label in annotation.itertracks(yield_label=True):
        turns.append((float(segment.start), float(segment.end), str(label)))
    return turns


def _label_map(turns: list[Turn]) -> dict[str, str]:
    """Map raw backend labels to 'Speaker N' by chronological first appearance."""
    mapping: dict[str, str] = {}
    for _start, _end, raw in sorted(turns, key=lambda t: (t[0], t[1])):
        if raw not in mapping:
            mapping[raw] = f"Speaker {len(mapping) + 1}"
    return mapping


def assign_speakers(
    segments: list[dict[str, Any]], turns: list[Turn]
) -> list[dict[str, Any]]:
    """Attach a speaker label to each segment by MAXIMUM TEMPORAL OVERLAP.

    Returns new segment dicts (the input is never mutated). A segment that
    overlaps no turn keeps ``speaker=None``.
    """
    labels = _label_map(turns)
    result: list[dict[str, Any]] = []

    for segment in segments:
        seg_start = float(segment["start"])
        seg_end = float(segment["end"])
        best_label: str | None = None
        best_overlap = 0.0

        for turn_start, turn_end, raw in turns:
            overlap = min(seg_end, turn_end) - max(seg_start, turn_start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_label = labels[raw]

        result.append({**segment, "speaker": best_label})

    return result


def diarize_segments(
    audio_path: str, segments: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Return segments with speaker labels when diarization is enabled and works.

    Degrades gracefully: on any failure (flag off, package missing, token
    rejected, backend crash) the segments come back unchanged with
    ``speaker=None``. Never raises.
    """
    if not segments:
        return list(segments)

    if not is_diarization_enabled():
        log.debug("diarization.disabled")
        return [{**segment} for segment in segments]

    try:
        pipeline = _load_pipeline()
        annotation = pipeline(audio_path)
        turns = _extract_turns(annotation)
    except ImportError:
        log.warning(
            "diarization.unavailable",
            reason="pyannote.audio is not installed",
            audio=audio_path,
        )
        return [{**segment} for segment in segments]
    except Exception as exc:
        log.warning(
            "diarization.failed",
            error=str(exc),
            error_type=type(exc).__name__,
            audio=audio_path,
        )
        return [{**segment} for segment in segments]

    if not turns:
        log.warning("diarization.no_turns", audio=audio_path)
        return [{**segment} for segment in segments]

    labelled = assign_speakers(segments, turns)
    log.info(
        "diarization.complete",
        audio=audio_path,
        segments=len(labelled),
        speakers=len({s["speaker"] for s in labelled if s["speaker"]}),
    )
    return labelled
