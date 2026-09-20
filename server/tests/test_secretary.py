# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for secretary-mode post-processing."""

from __future__ import annotations

from app.services.secretary import extract_action_items, format_meeting_transcript


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


# --------------------------------------------------------------------------
# format_meeting_transcript — must mirror the client's paragraph formatter
# (client/lib/services/meeting_transcript_formatter.dart) exactly, so a dump
# whose transcript was written by the server reads identically to one
# formatted on-device.
# --------------------------------------------------------------------------


def test_format_returns_none_without_usable_segments() -> None:
    assert format_meeting_transcript([]) is None
    assert format_meeting_transcript([{"start": 0.0, "text": "   "}]) is None
    assert format_meeting_transcript([{"start": 0.0}, "garbage", 42]) is None


def test_format_merges_null_speaker_segments_within_a_minute() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "end": 2.0, "speaker": None, "text": "First chunk."},
            {"start": 6.0, "end": 9.0, "speaker": None, "text": "Second chunk."},
            {"start": 22.0, "end": 25.0, "speaker": None, "text": "Third chunk."},
        ]
    )
    assert formatted == "[00:00] First chunk. Second chunk. Third chunk."


def test_format_breaks_paragraph_at_minute_boundary() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "text": "First chunk."},
            {"start": 30.0, "text": "Same minute."},
            {"start": 61.0, "text": "Second chunk."},
        ]
    )
    assert formatted == "[00:00] First chunk. Same minute.\n\n[01:01] Second chunk."


def test_format_renders_speaker_turns_with_labels() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": "Speaker 1", "text": "Hello there."},
            {"start": 247.5, "speaker": "Speaker 2", "text": "Follow up later."},
        ]
    )
    assert formatted == (
        "[00:00] Speaker 1: Hello there.\n\n[04:07] Speaker 2: Follow up later."
    )


def test_format_merges_same_speaker_across_minutes() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 5.0, "speaker": "Speaker 1", "text": "One."},
            {"start": 40.0, "speaker": "Speaker 1", "text": "Two."},
            {"start": 80.0, "speaker": "Speaker 1", "text": "Three."},
        ]
    )
    assert formatted == "[00:05] Speaker 1: One. Two. Three."


def test_format_hours_render_unpadded_and_only_when_needed() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 3540.0, "text": "before the hour"},
            {"start": 3661.9, "text": "after the hour"},
            {"start": 36000.0, "text": "ten hours in"},
        ]
    )
    assert formatted == (
        "[59:00] before the hour\n\n[1:01:01] after the hour\n\n[10:00:00] ten hours in"
    )


def test_format_never_invents_a_speaker_label() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": "Speaker 1", "text": "named"},
            {"start": 7.0, "speaker": None, "text": "unnamed"},
        ]
    )
    assert formatted == "[00:00] Speaker 1: named\n\n[00:07] unnamed"
    assert "None" not in formatted
