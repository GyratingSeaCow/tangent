# SPDX-License-Identifier: AGPL-3.0-or-later
"""Post-process transcripts. For 'meeting' mode, format diarised segments
as timestamped paragraphs (mirror of the client's
``meeting_transcript_formatter.dart`` — keep the two in lockstep so a
transcript written by the server reads identically to one formatted
on-device)."""

from __future__ import annotations

import re
from typing import Any

from app.logging_config import get_logger

log = get_logger(__name__)


# Patterns that suggest an action item / commitment.
_ACTION_PATTERNS = [
    re.compile(r"\b(?:I'll|I will|I'll go ahead and)\b[^.!?\n]+", re.IGNORECASE),
    re.compile(
        r"\b(?:we need to|let's|we should|we must|please|can you|could you|"
        r"don't forget to|remember to|make sure to)\b[^.!?\n]+",
        re.IGNORECASE,
    ),
    re.compile(r"\bTODO[:\s][^.!?\n]+", re.IGNORECASE),
    re.compile(r"\bACTION[:\s][^.!?\n]+", re.IGNORECASE),
]


def extract_action_items(transcript: str) -> list[str]:
    """Extract action items / commitments from a transcript.

    Heuristic — looks for commit phrases ("I'll …", "we need to …", etc.).
    Returns a de-duplicated list, ordered as they appear in the transcript.
    """
    if not transcript:
        return []

    candidates: list[str] = []
    seen: set[str] = set()

    for pattern in _ACTION_PATTERNS:
        for match in pattern.finditer(transcript):
            text = match.group(0).strip()
            # Strip trailing punctuation but keep meaning.
            text = text.rstrip(".,;:")
            if len(text) < 10 or len(text) > 200:
                continue
            # De-dup (case-insensitive).
            key = text.lower()
            if key in seen:
                continue
            seen.add(key)
            candidates.append(text)

    log.info("secretary.action_items_extracted", count=len(candidates))
    return candidates


def format_meeting_summary(transcript: str, action_items: list[str]) -> str:
    """Format a meeting transcript as a structured summary.

    Returns markdown with sections: Summary, Action Items, Full Transcript.
    """
    if not transcript:
        return ""

    lines: list[str] = []
    lines.append("# Meeting Summary\n")
    lines.append(
        f"_{len(transcript.split())} words · {len(action_items)} action items_\n"
    )

    if action_items:
        lines.append("\n## Action Items\n")
        for i, item in enumerate(action_items, start=1):
            lines.append(f"{i}. {item}\n")

    lines.append("\n## Transcript\n")
    lines.append(transcript)
    return "".join(lines)


def _seconds(value: Any) -> float:
    """Coerce a segment start to non-negative finite seconds (0 on garbage)."""
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return 0.0
    if parsed != parsed or parsed in (float("inf"), float("-inf")) or parsed < 0:
        return 0.0
    return parsed


def _label(value: Any) -> str | None:
    """A usable speaker label, or None — a label is never invented."""
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def _timestamp(start: float) -> str:
    """Elapsed `MM:SS` below one hour, `H:MM:SS` (hours unpadded) above.

    Fractional seconds floor rather than round so a marker never points past
    the audio it introduces.
    """
    total = int(_seconds(start))
    hours, minutes, seconds = total // 3600, (total % 3600) // 60, total % 60
    if hours == 0:
        return f"{minutes:02d}:{seconds:02d}"
    return f"{hours}:{minutes:02d}:{seconds:02d}"


def format_meeting_transcript(raw: Any) -> str | None:
    """Render a ``segments`` payload as timestamped paragraphs.

    Mirror of the client's ``formatMeetingTranscript``: consecutive segments
    merge into one paragraph while the speaker label is unchanged (both-None
    counts as unchanged) — named speakers merge for their whole turn,
    unattributed segments merge until a minute boundary passes. Attributed
    paragraphs render as ``[MM:SS] Name: text``; unattributed ones as
    ``[MM:SS] text``. Returns None when nothing is renderable so the caller
    keeps the plain transcript.
    """
    if not isinstance(raw, list):
        return None
    blocks: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        text = entry.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        text = text.strip()
        start = _seconds(entry.get("start"))
        speaker = _label(entry.get("speaker"))
        last = blocks[-1] if blocks else None
        if last is not None and last["speaker"] == speaker:
            same_minute = int(start) // 60 == int(last["start"]) // 60
            if speaker is not None or same_minute:
                last["texts"].append(text)
                continue
        blocks.append({"start": start, "speaker": speaker, "texts": [text]})
    if not blocks:
        return None
    rendered: list[str] = []
    for block in blocks:
        marker = f"[{_timestamp(block['start'])}]"
        body = " ".join(block["texts"])
        if block["speaker"] is None:
            rendered.append(f"{marker} {body}")
        else:
            rendered.append(f"{marker} {block['speaker']}: {body}")
    return "\n\n".join(rendered)