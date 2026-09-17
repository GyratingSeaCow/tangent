# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for optional pyannote speaker diarization.

Diarization is OFF by default. It only runs when TANGENT_DIARIZATION=pyannote
AND HF_TOKEN is set. It must never fabricate speaker labels: if the package or
the token is missing, speakers stay None and the segments come back otherwise
untouched.

No test here loads a real pyannote pipeline — the loader is monkeypatched.
"""

from __future__ import annotations

import pytest

from app.services import diarization


@pytest.fixture(autouse=True)
def _clear_diarization_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Start every test from 'diarization disabled'."""
    monkeypatch.delenv("TANGENT_DIARIZATION", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)


def _segments() -> list[dict]:
    return [
        {"start": 0.0, "end": 2.0, "speaker": None, "text": "Hello there."},
        {"start": 2.0, "end": 4.0, "speaker": None, "text": "Hi back."},
    ]


class _FakeTurn:
    def __init__(self, start: float, end: float) -> None:
        self.start = start
        self.end = end


class _FakeAnnotation:
    """Mimics pyannote.core.Annotation.itertracks(yield_label=True)."""

    def __init__(self, turns: list[tuple[float, float, str]]) -> None:
        self._turns = turns

    def itertracks(self, yield_label: bool = False):
        for index, (start, end, label) in enumerate(self._turns):
            if yield_label:
                yield _FakeTurn(start, end), f"track-{index}", label
            else:
                yield _FakeTurn(start, end), f"track-{index}"


# --------------------------------------------------------------------------
# Env gating
# --------------------------------------------------------------------------


def test_diarization_disabled_by_default() -> None:
    assert diarization.is_diarization_enabled() is False


def test_diarization_disabled_without_hf_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    assert diarization.is_diarization_enabled() is False


def test_diarization_disabled_for_unknown_backend(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "magic-ears")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    assert diarization.is_diarization_enabled() is False


def test_diarization_enabled_with_flag_and_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    assert diarization.is_diarization_enabled() is True


# --------------------------------------------------------------------------
# Overlap assignment (pure function)
# --------------------------------------------------------------------------


def test_assign_speakers_uses_maximum_temporal_overlap() -> None:
    segments = [{"start": 0.0, "end": 10.0, "speaker": None, "text": "long one"}]
    turns = [
        (0.0, 3.0, "SPEAKER_00"),
        (3.0, 10.0, "SPEAKER_01"),  # 7s of overlap beats 3s
    ]

    result = diarization.assign_speakers(segments, turns)

    assert [s["speaker"] for s in result] == ["Speaker 2"]


def test_assign_speakers_labels_speakers_in_first_appearance_order() -> None:
    segments = [
        {"start": 0.0, "end": 1.0, "speaker": None, "text": "a"},
        {"start": 1.0, "end": 2.0, "speaker": None, "text": "b"},
        {"start": 2.0, "end": 3.0, "speaker": None, "text": "c"},
    ]
    # Deliberately out of chronological order and with a re-appearance.
    turns = [
        (2.0, 3.0, "SPEAKER_07"),
        (0.0, 1.0, "SPEAKER_42"),
        (1.0, 2.0, "SPEAKER_07"),
    ]

    result = diarization.assign_speakers(segments, turns)

    # SPEAKER_42 starts at 0.0 so it is Speaker 1; SPEAKER_07 starts at 1.0 -> Speaker 2.
    assert [s["speaker"] for s in result] == ["Speaker 1", "Speaker 2", "Speaker 2"]


def test_assign_speakers_leaves_speaker_none_when_no_overlap() -> None:
    segments = [{"start": 0.0, "end": 1.0, "speaker": None, "text": "orphan"}]
    turns = [(50.0, 60.0, "SPEAKER_00")]

    result = diarization.assign_speakers(segments, turns)

    assert result[0]["speaker"] is None


def test_assign_speakers_does_not_mutate_input() -> None:
    segments = _segments()
    turns = [(0.0, 4.0, "SPEAKER_00")]

    result = diarization.assign_speakers(segments, turns)

    assert [s["speaker"] for s in result] == ["Speaker 1", "Speaker 1"]
    assert [s["speaker"] for s in segments] == [None, None]


def test_assign_speakers_preserves_text_and_timings() -> None:
    segments = _segments()
    turns = [(0.0, 2.0, "A"), (2.0, 4.0, "B")]

    result = diarization.assign_speakers(segments, turns)

    assert [(s["start"], s["end"], s["text"]) for s in result] == [
        (0.0, 2.0, "Hello there."),
        (2.0, 4.0, "Hi back."),
    ]


# --------------------------------------------------------------------------
# diarize_segments() orchestration + graceful degradation
# --------------------------------------------------------------------------


def test_diarize_segments_is_noop_when_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    def explode(*_args, **_kwargs):
        raise AssertionError("pipeline must not load when diarization is disabled")

    monkeypatch.setattr(diarization, "_load_pipeline", explode)

    result = diarization.diarize_segments("/tmp/audio.wav", _segments())

    assert [s["speaker"] for s in result] == [None, None]


def test_diarize_segments_assigns_labels_when_enabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    calls: list[str] = []

    def fake_pipeline(audio_path: str):
        calls.append(audio_path)
        return _FakeAnnotation([(0.0, 2.0, "SPEAKER_00"), (2.0, 4.0, "SPEAKER_01")])

    monkeypatch.setattr(diarization, "_load_pipeline", lambda: fake_pipeline)

    result = diarization.diarize_segments("/tmp/audio.wav", _segments())

    assert calls == ["/tmp/audio.wav"]
    assert [s["speaker"] for s in result] == ["Speaker 1", "Speaker 2"]


def test_diarize_segments_returns_null_speakers_when_pyannote_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Missing package must degrade, not raise. NEVER fabricate labels."""
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    def missing():
        raise ImportError("No module named 'pyannote'")

    monkeypatch.setattr(diarization, "_load_pipeline", missing)

    result = diarization.diarize_segments("/tmp/audio.wav", _segments())

    assert [s["speaker"] for s in result] == [None, None]
    assert [s["text"] for s in result] == ["Hello there.", "Hi back."]


def test_diarize_segments_returns_null_speakers_when_pipeline_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    def boom(_audio_path: str):
        raise RuntimeError("cuda exploded")

    monkeypatch.setattr(diarization, "_load_pipeline", lambda: boom)

    result = diarization.diarize_segments("/tmp/audio.wav", _segments())

    assert [s["speaker"] for s in result] == [None, None]


def test_diarize_segments_handles_empty_segment_list(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    def explode():
        raise AssertionError("pipeline must not load for zero segments")

    monkeypatch.setattr(diarization, "_load_pipeline", explode)

    assert diarization.diarize_segments("/tmp/audio.wav", []) == []


def test_extract_turns_reads_pyannote_annotation() -> None:
    annotation = _FakeAnnotation([(0.0, 1.5, "SPEAKER_00"), (1.5, 3.0, "SPEAKER_01")])

    assert diarization._extract_turns(annotation) == [
        (0.0, 1.5, "SPEAKER_00"),
        (1.5, 3.0, "SPEAKER_01"),
    ]


def test_extract_turns_reads_a_real_pyannote_annotation() -> None:
    """Guard the fake above against pyannote's actual Annotation API."""
    pytest.importorskip("pyannote.core")
    from pyannote.core import Annotation, Segment

    annotation = Annotation()
    annotation[Segment(0.0, 3.0)] = "SPEAKER_01"
    annotation[Segment(3.0, 7.0)] = "SPEAKER_00"

    assert diarization._extract_turns(annotation) == [
        (0.0, 3.0, "SPEAKER_01"),
        (3.0, 7.0, "SPEAKER_00"),
    ]


def test_extract_turns_unwraps_pyannote_4x_diarize_output() -> None:
    """pyannote 4.x pipelines return a DiarizeOutput wrapper, not an Annotation.

    Observed live in the container against speaker-diarization-3.1: the result
    object exposes .speaker_diarization (an Annotation) and has no itertracks
    of its own, so calling itertracks on it raises AttributeError.
    """

    class _DiarizeOutput:
        """Mirrors the real wrapper: no itertracks, annotation on an attribute."""

        def __init__(self, annotation: object) -> None:
            self.speaker_diarization = annotation
            self.exclusive_speaker_diarization = annotation
            self.speaker_embeddings = [[0.0]]

    wrapped = _DiarizeOutput(
        _FakeAnnotation([(0.03, 3.15, "SPEAKER_00"), (3.37, 6.51, "SPEAKER_01")])
    )

    assert diarization._extract_turns(wrapped) == [
        (0.03, 3.15, "SPEAKER_00"),
        (3.37, 6.51, "SPEAKER_01"),
    ]


# --------------------------------------------------------------------------
# Pipeline loading (model id + cross-version auth kwarg)
# --------------------------------------------------------------------------


def test_pipeline_uses_the_published_speaker_diarization_model() -> None:
    assert diarization.PYANNOTE_PIPELINE == "pyannote/speaker-diarization-3.1"


def test_load_pipeline_passes_token_kwarg_on_pyannote_4x(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """pyannote >= 3.3 renamed use_auth_token -> token; we must use the real name."""
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    diarization.reset_pipeline()
    seen: dict = {}

    class _Pipeline4x:
        @staticmethod
        def from_pretrained(checkpoint, *, token=None, **kwargs):
            seen["checkpoint"] = checkpoint
            seen["token"] = token
            seen["extra"] = kwargs
            return "pipeline-object"

    monkeypatch.setattr(diarization, "_import_pipeline", lambda: _Pipeline4x)

    assert diarization._load_pipeline() == "pipeline-object"
    assert seen["checkpoint"] == "pyannote/speaker-diarization-3.1"
    assert seen["token"] == "hf_fake"
    assert seen["extra"] == {}
    diarization.reset_pipeline()


def test_load_pipeline_falls_back_to_use_auth_token_on_pyannote_3x(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Older pyannote only accepts use_auth_token — don't crash on it."""
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    diarization.reset_pipeline()
    seen: dict = {}

    class _Pipeline3x:
        @staticmethod
        def from_pretrained(checkpoint, *, use_auth_token=None):
            seen["checkpoint"] = checkpoint
            seen["use_auth_token"] = use_auth_token
            return "old-pipeline"

    monkeypatch.setattr(diarization, "_import_pipeline", lambda: _Pipeline3x)

    assert diarization._load_pipeline() == "old-pipeline"
    assert seen == {
        "checkpoint": "pyannote/speaker-diarization-3.1",
        "use_auth_token": "hf_fake",
    }
    diarization.reset_pipeline()


def test_load_pipeline_matches_the_installed_pyannote_signature() -> None:
    """The auth kwarg we send must exist on the installed pyannote."""
    pytest.importorskip("pyannote.audio")
    import inspect

    from pyannote.audio import Pipeline

    params = inspect.signature(Pipeline.from_pretrained).parameters
    assert "token" in params or "use_auth_token" in params


def test_load_pipeline_raises_when_pyannote_returns_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A gated/unaccepted model yields None — that must surface as an error, not a crash later."""
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    diarization.reset_pipeline()

    class _NonePipeline:
        @staticmethod
        def from_pretrained(checkpoint, *, token=None):
            return None

    monkeypatch.setattr(diarization, "_import_pipeline", lambda: _NonePipeline)

    with pytest.raises(RuntimeError, match="no pipeline"):
        diarization._load_pipeline()
    diarization.reset_pipeline()


def test_diarize_segments_degrades_when_model_is_gated(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The None-pipeline error must degrade to null speakers, not fail the job."""
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    diarization.reset_pipeline()

    class _NonePipeline:
        @staticmethod
        def from_pretrained(checkpoint, *, token=None):
            return None

    monkeypatch.setattr(diarization, "_import_pipeline", lambda: _NonePipeline)

    result = diarization.diarize_segments("/tmp/audio.wav", _segments())

    assert [s["speaker"] for s in result] == [None, None]
    diarization.reset_pipeline()


def test_load_pipeline_caches_the_loaded_pipeline(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HF_TOKEN", "hf_fake")
    diarization.reset_pipeline()
    loads: list[int] = []

    class _CountingPipeline:
        @staticmethod
        def from_pretrained(checkpoint, *, token=None):
            loads.append(1)
            return "cached-pipeline"

    monkeypatch.setattr(diarization, "_import_pipeline", lambda: _CountingPipeline)

    assert diarization._load_pipeline() == "cached-pipeline"
    assert diarization._load_pipeline() == "cached-pipeline"
    assert sum(loads) == 1
    diarization.reset_pipeline()
