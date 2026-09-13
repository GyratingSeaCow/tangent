# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for secretary-mode post-processing."""

from __future__ import annotations

from app.services.secretary import extract_action_items, format_meeting_summary


def test_extracts_action_items_from_commit_phrases() -> None:
    transcript = (
        "We had a long meeting about the project. "
        "I'll send the slides out by Friday. "
        "We need to update the documentation before launch. "
        "Bob thinks the timeline is fine."
    )
    items = extract_action_items(transcript)
    assert any("Friday" in i for i in items)
    assert any("documentation" in i for i in items)
    # Bob's opinion is not an action item.
    assert not any("Bob thinks" in i for i in items)


def test_returns_empty_on_empty_input() -> None:
    assert extract_action_items("") == []


def test_dedupes() -> None:
    transcript = "I'll send it. I'll send it. I'll definitely send it."
    items = extract_action_items(transcript)
    # "I'll send it" and "I'll definitely send it" are different strings
    # so both survive; but "I'll send it" should not appear twice.
    seen = [s.lower() for s in items]
    assert len(seen) == len(set(seen))


def test_format_meeting_summary_has_sections() -> None:
    transcript = "I'll do the thing. Let's meet again next week."
    items = extract_action_items(transcript)
    summary = format_meeting_summary(transcript, items)
    assert "Meeting Summary" in summary
    assert "Action Items" in summary
    assert "Transcript" in summary
    assert transcript in summary