# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.services.transcription. Uses a fake model to avoid loading real Whisper."""


from app.services.transcription import TranscriptionService


class FakeWhisperModel:
    """Stand-in for faster_whisper.WhisperModel."""

    def __init__(self, model_name: str, **kwargs):
        self.model_name = model_name
        self.kwargs = kwargs

    def transcribe(self, audio_path: str, **kwargs):
        # Return a shape matching faster-whisper's API: (segments_iter, info_obj_with_attrs)
        class _Segment:
            text = "fake segment text"

        class _Info:
            language = "en"

        return ([_Segment()], _Info())


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

    text1 = service.transcribe(str(audio))
    assert text1 == "fake segment text"
    assert service._model is not None

    # Second call should NOT reload
    original_model = service._model
    text2 = service.transcribe(str(audio))
    assert text2 == "fake segment text"
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

    text = service.transcribe(str(audio))
    assert text == ""
