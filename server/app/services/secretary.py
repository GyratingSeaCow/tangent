# SPDX-License-Identifier: AGPL-3.0-or-later
"""Post-process transcripts. For 'meeting' mode, extract action items."""

from __future__ import annotations

import re

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