# SPDX-License-Identifier: AGPL-3.0-or-later
"""Server-owned summary-template definitions and prompt assembly.

Template IDs are stable wire values. Sampling stays in ``summarize_infer``;
this module changes prompts only.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass

CUSTOM_PROMPT_SETTINGS_KEY = "summary_custom_prompt"

MEETING_PROMPT = """\
You are a meeting-summarization assistant. Given a raw meeting transcript,
produce a structured summary in Markdown using EXACTLY this template:

## Summary
<2-5 sentence overview of the meeting>

## Key decisions
- <one bullet per decision explicitly made>

## Action items
- <who>: <what> (attribute only to names or speakers present in the transcript)

## Open questions
- <one bullet per question raised but not resolved>

Rules:
- Extract exhaustively: capture every decision, action item, and open
  question that appears in the transcript.
- Only include items explicitly discussed in the transcript.
- Never invent names, numbers, or dates.
- If a section has no items, write exactly "None" under its heading.
- Write the output in the same language as the transcript.

Example:

Transcript:
Ana: We need to pick a database for the analytics service.
Ben: Postgres has worked for us before, and the team knows it. Let's use it.
Ana: Agreed. Can you have the schema drafted by Friday?
Ben: Yes, I'll have it ready.

Output:
## Summary
Ana and Ben discussed the database choice for the analytics service and
settled on Postgres because the team already knows it. Ben committed to
drafting the schema by Friday.

## Key decisions
- Use Postgres for the analytics service.

## Action items
- Ben: draft the database schema by Friday.

## Open questions
None
"""

BRAIN_DUMP_PROMPT = """\
You are a brain-dump summarization assistant. Given a raw brain-dump transcript,
produce a structured summary in Markdown using EXACTLY this template:

## Overview
<2-5 sentence overview of the speaker's thoughts>

## Key points
- <one bullet per important idea, fact, concern, or constraint>

## Follow-ups
- <one bullet per next step or item worth revisiting>

Rules:
- Capture the speaker's ideas faithfully without attendee or meeting framing.
- Only include information explicitly present in the transcript.
- Never invent names, numbers, or dates.
- If a section has no items, write exactly "None" under its heading.
- Write the output in the same language as the transcript.
"""

LECTURE_PROMPT = """\
You are a lecture-summarization assistant. Given a raw lecture transcript,
produce structured study notes in Markdown using EXACTLY this template:

## Topic outline
- <the lecture topics in the order presented>

## Key concepts
- <one bullet per important concept or explanation>

## Terms and definitions
- <term>: <definition given or supported by the transcript>

## Questions to review
- <one bullet per question left unanswered or worth revisiting>

Rules:
- Capture the lecture content faithfully and exhaustively.
- Only include information explicitly present in the transcript.
- Never invent terms, definitions, facts, or questions.
- If a section has no items, write exactly "None" under its heading.
- Write the output in the same language as the transcript.
"""

ACTIONS_ONLY_PROMPT = """\
You are an action-item extraction assistant. Given a raw transcript, produce
Markdown using EXACTLY this template:

## Action items
- <owner>: <action> (include a deadline only when explicitly stated)

Rules:
- Extract every explicit action item with its owners, and output nothing else.
- Attribute an owner only when the transcript identifies one; otherwise use
  the transcript language's equivalent of "Unassigned".
- Never invent names, actions, numbers, or dates.
- If there are no action items, write exactly "None" under the heading.
- Write the output in the same language as the transcript.
"""

CUSTOM_CONTRACT_SUFFIX = """

Mandatory output contract:
- Use only the Markdown headings requested above and reproduce them exactly;
  do not add, remove, rename, or reorder headings.
- If a requested section has no items, write exactly "None" under its heading.
- Write the output in the same language as the transcript."""


@dataclass(frozen=True)
class SummaryTemplate:
    id: str
    display_name: str
    prompt: str | None


TEMPLATE_DEFINITIONS = (
    SummaryTemplate("meeting", "Meeting", MEETING_PROMPT),
    SummaryTemplate("brain_dump", "Brain dump", BRAIN_DUMP_PROMPT),
    SummaryTemplate("lecture", "Lecture", LECTURE_PROMPT),
    SummaryTemplate("actions_only", "Actions only", ACTIONS_ONLY_PROMPT),
    SummaryTemplate("custom", "Custom", None),
)
TEMPLATE_IDS = frozenset(item.id for item in TEMPLATE_DEFINITIONS)
_PROMPTS = {item.id: item.prompt for item in TEMPLATE_DEFINITIONS}


def default_template_id(mode: str) -> str:
    """Mode-based default. Typed notes use the general brain-dump shape."""
    return "meeting" if mode == "meeting" else "brain_dump"


def assemble_prompt(template_id: str, *, custom_prompt: str | None = None) -> str:
    """Return a complete prompt, appending the mandatory custom contract."""
    if template_id not in TEMPLATE_IDS:
        raise ValueError(f"Unknown summary template: {template_id}")
    if template_id == "custom":
        authored = (custom_prompt or "").strip()
        if not authored:
            raise ValueError("Custom summary template is not configured")
        return authored + CUSTOM_CONTRACT_SUFFIX
    prompt = _PROMPTS[template_id]
    assert prompt is not None
    return prompt


def get_custom_prompt(db: sqlite3.Connection) -> str | None:
    """Return the configured custom prompt, treating blank text as absent."""
    row = db.execute(
        "SELECT value FROM app_settings WHERE key = ?",
        (CUSTOM_PROMPT_SETTINGS_KEY,),
    ).fetchone()
    if row is None:
        return None
    value = str(row[0]).strip()
    return value or None


def set_custom_prompt(db: sqlite3.Connection, prompt: str | None) -> None:
    """Persist the one custom slot; blank text clears it."""
    value = (prompt or "").strip()
    if value:
        db.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
            (CUSTOM_PROMPT_SETTINGS_KEY, value),
        )
    else:
        db.execute(
            "DELETE FROM app_settings WHERE key = ?", (CUSTOM_PROMPT_SETTINGS_KEY,)
        )
    db.commit()
