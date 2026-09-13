# SPDX-License-Identifier: AGPL-3.0-or-later
"""Wraps faster-whisper. Loads model once, reuses across transcribe() calls."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from app.config import get_settings
from app.logging_config import get_logger

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

log = get_logger(__name__)


class TranscriptionService:
    """Lazy-loads Whisper model on first use, caches it for the process lifetime."""

    def __init__(self, model_name: str | None = None) -> None:
        self._model_name = model_name or get_settings().whisper_model
        self._model: "WhisperModel | None" = None

    @property
    def model_name(self) -> str:
        return self._model_name

    def load_model(self, model_name: str | None = None) -> None:
        """Explicitly load (or reload) the model."""
        from faster_whisper import WhisperModel

        target = model_name or self._model_name
        log.info("transcription.loading_model", model=target)
        # device="auto" lets faster-whisper pick CPU/CUDA; compute_type="int8" for CPU friendliness
        self._model = WhisperModel(target, device="auto", compute_type="int8")
        self._model_name = target
        log.info("transcription.model_loaded", model=target)

    def transcribe(self, audio_path: str) -> str:
        """Transcribe an audio file to text. Returns empty string if no speech detected."""
        if self._model is None:
            self.load_model()

        log.info("transcription.start", audio=audio_path, model=self._model_name)
        segments: Any
        info: Any
        segments, info = self._model.transcribe(
            audio_path,
            beam_size=5,
            vad_filter=True,
            language=None,  # auto-detect
        )
        log.info("transcription.detected_language", language=info.language)

        text_parts: list[str] = []
        for segment in segments:
            text_parts.append(segment.text.strip())

        return " ".join(p for p in text_parts if p)


# Module-level singleton
_service: TranscriptionService | None = None


def get_transcription_service() -> TranscriptionService:
    """Get the singleton TranscriptionService."""
    global _service
    if _service is None:
        _service = TranscriptionService()
    return _service


def reset_transcription_service() -> None:
    """Reset the singleton. Useful for tests and model switching."""
    global _service
    _service = None