# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pure rendering of per-recording speaker names."""

from __future__ import annotations

import json
import re

_SPEAKER_LINE = re.compile(r"(?m)^(## )?(Speaker [0-9]+)(?=:\s|\s*$)")


def render_speaker_names(transcript: str, speaker_names: str | None) -> str:
    """Render mapped headings and line-leading turn labels without touching prose."""
    if not speaker_names:
        return transcript
    try:
        names = json.loads(speaker_names)
    except (TypeError, ValueError):
        return transcript
    if not isinstance(names, dict) or not names:
        return transcript

    def replace(match: re.Match[str]) -> str:
        prefix, label = match.groups()
        name = names.get(label)
        return f"{prefix or ''}{name}" if isinstance(name, str) else match.group(0)

    return _SPEAKER_LINE.sub(replace, transcript)
