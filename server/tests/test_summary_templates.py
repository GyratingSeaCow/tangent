# SPDX-License-Identifier: AGPL-3.0-or-later
"""Summary-template preset and prompt-contract tests."""

import pytest

from app.summary_templates import (
    CUSTOM_CONTRACT_SUFFIX,
    MEETING_PROMPT,
    MORNING_BRIEF_TEMPLATE_ID,
    PER_DUMP_TEMPLATES,
    TEMPLATE_DEFINITIONS,
    TEMPLATE_IDS,
    assemble_prompt,
    default_template_id,
    morning_brief_prompt,
)

# Drift guard: this is the v1.12.0 SYSTEM_PROMPT copied verbatim. Comparing the
# exported meeting preset to another alias would let both silently drift.
FORMER_SYSTEM_PROMPT = """\
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


def test_template_ids_and_display_names_are_stable_and_ordered():
    assert [(item.id, item.display_name) for item in TEMPLATE_DEFINITIONS] == [
        ("meeting", "Meeting"),
        ("brain_dump", "Brain dump"),
        ("lecture", "Lecture"),
        ("actions_only", "Actions only"),
        ("custom", "Custom"),
        ("morning_brief", "Morning brief"),
    ]
    # The per-dump set (client picker, assemble_prompt) is unchanged.
    assert [item.id for item in PER_DUMP_TEMPLATES] == [
        "meeting",
        "brain_dump",
        "lecture",
        "actions_only",
        "custom",
    ]


def test_morning_brief_is_not_a_per_dump_template():
    assert MORNING_BRIEF_TEMPLATE_ID not in TEMPLATE_IDS
    with pytest.raises(ValueError, match="Unknown summary template"):
        assemble_prompt(MORNING_BRIEF_TEMPLATE_ID)


def test_morning_brief_prompt_shape_and_single_worked_example():
    prompt = morning_brief_prompt()
    assert prompt.count("Example:") == 1
    assert prompt.count("Output:") == 1
    assert "**Highlights**" in prompt
    assert "Never invent" in prompt
    for heading in ("## Captured yesterday", "## Due today", "## Pinned"):
        assert heading in prompt


def test_meeting_preset_exactly_equals_the_former_system_prompt():
    assert MEETING_PROMPT == FORMER_SYSTEM_PROMPT


def test_builtin_prompts_match_the_specified_structures():
    prompts = {item.id: item.prompt for item in TEMPLATE_DEFINITIONS}
    assert [
        heading
        for heading in ("## Overview", "## Key points", "## Follow-ups")
        if heading in prompts["brain_dump"]
    ] == ["## Overview", "## Key points", "## Follow-ups"]
    assert "attendee" in prompts["brain_dump"].lower()
    assert "meeting framing" in prompts["brain_dump"].lower()

    for heading in (
        "## Topic outline",
        "## Key concepts",
        "## Terms and definitions",
        "## Questions to review",
    ):
        assert heading in prompts["lecture"]

    actions = prompts["actions_only"]
    assert "## Action items" in actions
    assert "owners" in actions.lower()
    assert "nothing else" in actions.lower()
    assert "## Summary" not in actions
    assert prompts["custom"] is None


def test_custom_prompt_gets_the_mandatory_contract_appended_server_side():
    authored = "Use exactly these headings:\n## Wins\n## Risks"
    assembled = assemble_prompt("custom", custom_prompt=authored)
    assert assembled == authored + CUSTOM_CONTRACT_SUFFIX
    assert "do not add, remove, rename, or reorder headings" in assembled
    assert 'write exactly "None"' in assembled
    assert "same language as the transcript" in assembled


def test_mode_defaults_include_text_notes_as_brain_dumps():
    assert default_template_id("meeting") == "meeting"
    assert default_template_id("brain_dump") == "brain_dump"
    assert default_template_id("text_note") == "brain_dump"
