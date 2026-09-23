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
# format_meeting_transcript — must mirror the client's speaker-digest
# formatter (client/lib/services/meeting_transcript_formatter.dart) exactly,
# so a dump whose transcript was written by the server reads identically to
# one formatted on-device.
# --------------------------------------------------------------------------


def test_format_returns_none_without_usable_segments() -> None:
    assert format_meeting_transcript([]) is None
    assert format_meeting_transcript([{"start": 0.0, "text": "   "}]) is None
    assert format_meeting_transcript([{"start": 0.0}, "garbage", 42]) is None


def test_format_merges_null_speaker_segments_within_a_minute() -> None:
    """Zero speakers -> the timestamped-paragraph fallback, merged by minute."""
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


def test_format_renders_one_section_per_speaker() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": "Speaker 1", "text": "Hello there."},
            {"start": 247.5, "speaker": "Speaker 2", "text": "Follow up later."},
        ]
    )
    assert formatted == (
        "## Speaker 1\n\nHello there.\n\n## Speaker 2\n\nFollow up later."
    )


def test_format_collects_a_speakers_segments_one_per_line() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 5.0, "speaker": "Speaker 1", "text": "One."},
            {"start": 40.0, "speaker": "Speaker 1", "text": "Two."},
            {"start": 80.0, "speaker": "Speaker 1", "text": "Three."},
        ]
    )
    assert formatted == "## Speaker 1\n\nOne.\nTwo.\nThree."


def test_format_interleaved_speakers_stay_chronological_within_sections() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": "Ada", "text": "a1"},
            {"start": 10.0, "speaker": "Bob", "text": "b1"},
            {"start": 20.0, "speaker": "Ada", "text": "a2"},
        ]
    )
    assert formatted == "## Speaker 1\n\na1\na2\n\n## Speaker 2\n\nb1"


def test_format_renumbers_speakers_by_first_appearance() -> None:
    """Raw diarization labels are arbitrary — whoever speaks first is Speaker 1."""
    formatted = format_meeting_transcript(
        [
            # Payload order deliberately not chronological.
            {"start": 12.0, "speaker": "SPEAKER_07", "text": "Second voice."},
            {"start": 0.0, "speaker": "SPEAKER_03", "text": "First voice."},
            {"start": 20.0, "speaker": "SPEAKER_03", "text": "First voice again."},
        ]
    )
    assert formatted == (
        "## Speaker 1\n\nFirst voice.\nFirst voice again.\n\n## Speaker 2\n\nSecond voice."
    )


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
    assert formatted == "## Speaker 1\n\nnamed\n\n## [unattributed]\n\nunnamed"
    assert "None" not in formatted


def test_format_unattributed_section_renders_last_even_when_first_spoken() -> None:
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": None, "text": "Mystery opener."},
            {"start": 5.0, "speaker": "Speaker 1", "text": "Named reply."},
        ]
    )
    assert formatted == "## Speaker 1\n\nNamed reply.\n\n## [unattributed]\n\nMystery opener."


def test_format_zero_speakers_falls_back_to_timestamped_paragraphs() -> None:
    """No diarised speakers at all -> the old rendering, never one giant
    [unattributed] section."""
    formatted = format_meeting_transcript(
        [
            {"start": 0.0, "speaker": None, "text": "Solo thought."},
            {"start": 61.0, "speaker": None, "text": "Another minute."},
        ]
    )
    assert formatted == "[00:00] Solo thought.\n\n[01:01] Another minute."
    assert "##" not in formatted
    assert "[unattributed]" not in formatted


# Shared cross-check fixture: the client test suite hardcodes THIS EXACT
# input and expected string (meeting_transcript_formatter_test.dart,
# 'matches the server formatter byte for byte'). If you change either side,
# change both.
CROSS_CHECK_SEGMENTS = [
    {"start": 12.0, "end": 15.0, "speaker": "SPEAKER_07", "text": "Second speaker opener."},
    {"start": 0.0, "end": 4.0, "speaker": "SPEAKER_02", "text": "Kickoff."},
    {"start": 7.5, "end": 11.0, "speaker": None, "text": "Crosstalk nobody owns."},
    {"start": 18.0, "end": 21.0, "speaker": "SPEAKER_02", "text": "Wrapping up."},
]
CROSS_CHECK_EXPECTED = (
    "## Speaker 1\n\nKickoff.\nWrapping up.\n\n"
    "## Speaker 2\n\nSecond speaker opener.\n\n"
    "## [unattributed]\n\nCrosstalk nobody owns."
)


def test_format_matches_the_client_formatter_byte_for_byte() -> None:
    assert format_meeting_transcript(CROSS_CHECK_SEGMENTS) == CROSS_CHECK_EXPECTED
