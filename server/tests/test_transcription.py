# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.services.transcription. Uses a fake model to avoid loading real Whisper."""

import pytest

from app.services.transcription import TranscriptionResult, TranscriptionService


class FakeWhisperModel:
    """Stand-in for faster_whisper.WhisperModel."""

    def __init__(self, model_name: str, **kwargs):
        self.model_name = model_name
        self.kwargs = kwargs

    def transcribe(self, audio_path: str, **kwargs):
        # Return a shape matching faster-whisper's API: (segments_iter, info_obj_with_attrs)
        class _Segment:
            start = 0.0
            end = 1.5
            text = "fake segment text"

        class _Info:
            language = "en"

        return ([_Segment()], _Info())


def _seg(start: float, end: float, text: str):
    """Build an object shaped like a faster-whisper segment."""

    class _Seg:
        pass

    s = _Seg()
    s.start = start
    s.end = end
    s.text = text
    return s


@pytest.fixture(autouse=True)
def _diarization_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """Transcription tests must never depend on diarization being configured."""
    monkeypatch.delenv("TANGENT_DIARIZATION", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)


def test_service_loads_model_lazy(monkeypatch, tmp_path):
    """First transcribe() call should load the model; second should reuse."""
    monkeypatch.setattr(
        "faster_whisper.WhisperModel", FakeWhisperModel
    )

    service = TranscriptionService(model_name="large-v3")

    # Initially no model loaded
    assert service._model is None

    # Fake audio file
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result1 = service.transcribe(str(audio))
    assert result1.text == "fake segment text"
    assert service._model is not None

    # Second call should NOT reload
    original_model = service._model
    result2 = service.transcribe(str(audio))
    assert result2.text == "fake segment text"
    assert service._model is original_model


def test_service_loads_model_from_persistent_data_dir(monkeypatch, tmp_path):
    model_root = tmp_path / "persistent-data"
    monkeypatch.setenv("TANGENT_DATA_DIR", str(model_root))
    monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)

    service = TranscriptionService(model_name="large-v3")
    service.load_model()

    assert service._model.kwargs["download_root"] == str(model_root / "models")


def test_service_returns_empty_string_for_empty_segments(monkeypatch, tmp_path):
    class EmptyModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            class _Info:
                language = "en"

            return ([], _Info())

    monkeypatch.setattr(
        "faster_whisper.WhisperModel", EmptyModel
    )

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))
    assert result.text == ""
    assert result.segments == []


def test_transcribe_returns_segment_level_timestamps(monkeypatch, tmp_path):
    """transcribe() returns the joined text AND per-segment elapsed-second timings."""

    class TimedModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            class _Info:
                language = "en"

            return (
                [
                    _seg(0.0, 2.5, " Hello world. "),
                    _seg(2.5, 5.25, " Second part. "),
                ],
                _Info(),
            )

    monkeypatch.setattr("faster_whisper.WhisperModel", TimedModel)

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))

    assert isinstance(result, TranscriptionResult)
    # Joined transcript keeps its old value/behavior.
    assert result.text == "Hello world. Second part."
    assert result.segments == [
        {
            "start": 0.0,
            "end": 2.5,
            "speaker": None,
            "text": "Hello world.",
            "words": [],
        },
        {
            "start": 2.5,
            "end": 5.25,
            "speaker": None,
            "text": "Second part.",
            "words": [],
        },
    ]


def test_segment_timestamps_are_floats_even_when_model_yields_ints(monkeypatch, tmp_path):
    class IntModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            class _Info:
                language = "en"

            return ([_seg(0, 3, "ints please")], _Info())

    monkeypatch.setattr("faster_whisper.WhisperModel", IntModel)

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    segment = service.transcribe(str(audio)).segments[0]

    assert isinstance(segment["start"], float)
    assert isinstance(segment["end"], float)
    assert (segment["start"], segment["end"]) == (0.0, 3.0)


def test_blank_segments_are_dropped_from_segments_and_text(monkeypatch, tmp_path):
    class BlankyModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            class _Info:
                language = "en"

            return (
                [
                    _seg(0.0, 1.0, "  "),
                    _seg(1.0, 2.0, " real words "),
                    _seg(2.0, 3.0, ""),
                ],
                _Info(),
            )

    monkeypatch.setattr("faster_whisper.WhisperModel", BlankyModel)

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))

    assert result.text == "real words"
    assert result.segments == [
        {
            "start": 1.0,
            "end": 2.0,
            "speaker": None,
            "text": "real words",
            "words": [],
        }
    ]


def test_speakers_stay_none_when_diarization_disabled(monkeypatch, tmp_path):
    """Default config must never fabricate speaker labels."""
    monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))

    assert [s["speaker"] for s in result.segments] == [None]


def test_transcribe_applies_diarization_when_enabled(monkeypatch, tmp_path):
    """When TANGENT_DIARIZATION=pyannote + HF_TOKEN, segments carry speaker labels."""

    class TwoSpeakerModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            class _Info:
                language = "en"

            return (
                [_seg(0.0, 2.0, "Hello there."), _seg(2.0, 4.0, "Hi back.")],
                _Info(),
            )

    monkeypatch.setattr("faster_whisper.WhisperModel", TwoSpeakerModel)
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    seen: list[str] = []

    def fake_diarize(audio_path, segments):
        seen.append(audio_path)
        labels = ["Speaker 1", "Speaker 2"]
        return [
            {**segment, "speaker": label}
            for segment, label in zip(segments, labels, strict=False)
        ]

    monkeypatch.setattr(
        "app.services.transcription.diarize_segments", fake_diarize
    )

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))

    assert seen == [str(audio)]
    assert [s["speaker"] for s in result.segments] == ["Speaker 1", "Speaker 2"]
    # Joined transcript is unaffected by diarization.
    assert result.text == "Hello there. Hi back."


def test_diarization_failure_does_not_fail_transcription(monkeypatch, tmp_path):
    monkeypatch.setattr("faster_whisper.WhisperModel", FakeWhisperModel)
    monkeypatch.setenv("TANGENT_DIARIZATION", "pyannote")
    monkeypatch.setenv("HF_TOKEN", "hf_fake")

    def exploding_diarize(audio_path, segments):
        raise RuntimeError("diarization backend unavailable")

    monkeypatch.setattr(
        "app.services.transcription.diarize_segments", exploding_diarize
    )

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    result = service.transcribe(str(audio))

    assert result.text == "fake segment text"
    assert [s["speaker"] for s in result.segments] == [None]
