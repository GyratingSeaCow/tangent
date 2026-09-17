# SPDX-License-Identifier: AGPL-3.0-or-later
"""Wraps faster-whisper. Loads model once, reuses across transcribe() calls."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

from app.config import get_settings
from app.logging_config import get_logger
from app.services.diarization import diarize_segments

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

log = get_logger(__name__)


@dataclass
class TranscriptionResult:
    """A transcription: the joined plain text plus per-segment timings.

    ``text`` is the whole transcript joined with single spaces (unchanged from
    the pre-segments behavior).

    ``segments`` is a list of
    ``{"start": float, "end": float, "speaker": str | None, "text": str}``
    where start/end are ELAPSED SECONDS from the start of the audio (never
    wall-clock), and ``speaker`` is None unless diarization actually ran.
    """

    text: str
    segments: list[dict[str, Any]] = field(default_factory=list)


class TranscriptionService:
    """Lazy-loads Whisper model on first use, caches it for the process lifetime."""

    def __init__(self, model_name: str | None = None) -> None:
        self._model_name = model_name or get_settings().whisper_model
        self._model: WhisperModel | None = None

    @property
    def model_name(self) -> str:
        return self._model_name

    def load_model(self, model_name: str | None = None) -> None:
        """Explicitly load (or reload) the model."""
        from faster_whisper import WhisperModel

        target = model_name or self._model_name
        download_root = Path(get_settings().data_dir) / "models"
        download_root.mkdir(parents=True, exist_ok=True)
        log.info(
            "transcription.loading_model",
            model=target,
            download_root=str(download_root),
        )
        # device="auto" lets faster-whisper pick CPU/CUDA; compute_type="int8" for CPU friendliness
        self._model = WhisperModel(
            target,
            device="auto",
            compute_type="int8",
            download_root=str(download_root),
        )
        self._model_name = target
        log.info("transcription.model_loaded", model=target)

    def transcribe(self, audio_path: str) -> TranscriptionResult:
        """Transcribe an audio file.

        Returns a TranscriptionResult holding the joined transcript (empty
        string if no speech was detected) and the per-segment timestamps.
        Speaker labels are filled in only when diarization is enabled and
        succeeds; otherwise they stay None.
        """
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

        collected: list[dict[str, Any]] = []
        for segment in segments:
            text = segment.text.strip()
            if not text:
                continue
            collected.append(
                {
                    "start": float(segment.start),
                    "end": float(segment.end),
                    "speaker": None,
                    "text": text,
                }
            )

        joined = " ".join(s["text"] for s in collected)

        # Diarization is optional and must never break transcription.
        try:
            collected = diarize_segments(audio_path, collected)
        except Exception as exc:
            log.warning(
                "transcription.diarization_skipped",
                error=str(exc),
                error_type=type(exc).__name__,
                audio=audio_path,
            )

        log.info(
            "transcription.complete",
            audio=audio_path,
            segments=len(collected),
            characters=len(joined),
        )
        return TranscriptionResult(text=joined, segments=collected)


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
