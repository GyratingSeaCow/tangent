# SPDX-License-Identifier: AGPL-3.0-or-later
"""Wraps faster-whisper. Loads model once, reuses across transcribe() calls."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

from app.config import get_settings
from app.logging_config import get_logger
from app.services.diarization import diarize_segments

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

log = get_logger(__name__)

WAVEFORM_BUCKETS = 600


def _decode_audio_samples(audio_path: str) -> Any:
    """Decode once to Whisper's canonical 16 kHz float32 mono waveform."""
    from faster_whisper.audio import decode_audio

    return decode_audio(audio_path, sampling_rate=16000)


def compute_waveform_peaks(
    samples: Any, bucket_count: int = WAVEFORM_BUCKETS
) -> list[float]:
    """Return fixed-width normalized RMS buckets for waveform rendering."""
    sample_count = len(samples)
    if sample_count == 0:
        return [0.0] * bucket_count

    rms_values: list[float] = []
    for index in range(bucket_count):
        start = index * sample_count // bucket_count
        end = (index + 1) * sample_count // bucket_count
        if start == end:
            rms_values.append(0.0)
            continue
        bucket = samples[start:end]
        try:
            mean_square = float((bucket * bucket).mean())
        except (AttributeError, TypeError):
            mean_square = sum(float(sample) ** 2 for sample in bucket) / len(bucket)
        rms_values.append(math.sqrt(mean_square))

    maximum = max(rms_values)
    if maximum == 0.0:
        return [0.0] * bucket_count
    return [round(value / maximum, 3) for value in rms_values]


def _cuda_runtime_loadable() -> bool:
    """Can ctranslate2 actually run a CUDA kernel here?

    Device visibility is NOT enough: docker-compose.gpu.yml can expose the
    GPU while the image lacks the CUDA 12 runtime ctranslate2 links against
    (libcublas.so.12, cudnn 9) — torch ships CUDA 13 wheels. In that state
    model LOAD succeeds (libraries load lazily) and the first inference
    dies with 'Library libcublas.so.12 is not found'. So probe by loading
    the libraries themselves, not by counting devices.
    """
    import ctypes

    try:
        import ctranslate2

        if ctranslate2.get_cuda_device_count() < 1:
            return False
        # The exact libraries ctranslate2 dlopens at inference time. If
        # either is missing we WILL crash mid-transcription — treat the
        # GPU as unusable now, while we can still choose CPU.
        for lib in ("libcublas.so.12", "libcudnn_ops.so.9"):
            ctypes.CDLL(lib)
        return True
    except Exception:
        return False


def resolve_whisper_device() -> str:
    """Pick the device Whisper runs on. See tests/test_whisper_device.py.

    TANGENT_WHISPER_DEVICE=cpu|cuda overrides the probe: cpu skips it,
    cuda is honored even if the probe fails (explicit opt-in fails loud
    rather than silently degrading to CPU forever).
    """
    import os

    override = os.environ.get("TANGENT_WHISPER_DEVICE", "").strip().lower()
    if override in ("cpu", "cuda"):
        return override
    return "cuda" if _cuda_runtime_loadable() else "cpu"


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
    peaks: list[float] = field(default_factory=list)


def resolve_configured_model() -> str:
    """The model the server should transcribe with, resolved against the db.

    Opens its OWN short-lived connection (and only when the database file
    already exists) so a model load never creates or migrates the schema as
    a side effect. Any failure degrades to the env/default resolution rather
    than failing the transcription — see ``storage.resolve_active_model``.
    """
    import sqlite3

    from app.services.storage import resolve_active_model

    db_path = Path(get_settings().data_dir) / "tangent.db"
    if not db_path.exists():
        return resolve_active_model(None)
    conn = None
    try:
        conn = sqlite3.connect(db_path)
        return resolve_active_model(conn)
    except Exception as exc:
        log.warning("transcription.model_resolution_failed", error=str(exc))
        return resolve_active_model(None)
    finally:
        if conn is not None:
            conn.close()


class TranscriptionService:
    """Lazy-loads Whisper model on first use, caches it for the process lifetime."""

    def __init__(self, model_name: str | None = None) -> None:
        #: An EXPLICIT name pins the service to that model (the /pull route
        #: and tests). None means "whatever is selected", resolved at LOAD
        #: time — never in __init__ — so a selection made through the API
        #: takes effect on the next load with no container restart.
        self._pinned_name = model_name
        self._model_name = model_name or resolve_configured_model()
        self._model: WhisperModel | None = None

    @property
    def model_name(self) -> str:
        return self._model_name

    def load_model(self, model_name: str | None = None) -> None:
        """Explicitly load (or reload) the model."""
        from faster_whisper import WhisperModel

        target = model_name or self._pinned_name or resolve_configured_model()
        download_root = Path(get_settings().data_dir) / "models"
        download_root.mkdir(parents=True, exist_ok=True)
        log.info(
            "transcription.loading_model",
            model=target,
            download_root=str(download_root),
        )
        # resolve_whisper_device probes whether the CUDA runtime can
        # actually execute (not just whether a GPU is visible) — the
        # libcublas.so.12 regression. int8 works on both CPU and CUDA.
        device = resolve_whisper_device()
        self._model = WhisperModel(
            target,
            device=device,
            compute_type="int8",
            download_root=str(download_root),
        )
        self._model_name = target
        log.info("transcription.model_loaded", model=target, device=device)

    def transcribe(
        self, audio_path: str, *, hotwords: str | None = None
    ) -> TranscriptionResult:
        """Transcribe an audio file.

        Returns a TranscriptionResult holding the joined transcript (empty
        string if no speech was detected) and the per-segment timestamps.
        Speaker labels are filled in only when diarization is enabled and
        succeeds; otherwise they stay None.
        """
        if self._model is None:
            self.load_model()

        log.info(
            "transcription.start",
            audio=audio_path,
            model=self._model_name,
            hotword_terms=0 if hotwords is None else len(hotwords.split(", ")),
        )
        audio_samples = _decode_audio_samples(audio_path)
        peaks = compute_waveform_peaks(audio_samples)
        segments: Any
        info: Any
        segments, info = self._model.transcribe(
            audio_samples,
            beam_size=5,
            vad_filter=True,
            word_timestamps=True,
            language=None,  # auto-detect
            hotwords=hotwords,
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
                    "words": [
                        {
                            "w": word.word.strip(),
                            "s": float(word.start),
                            "e": float(word.end),
                            "p": float(word.probability),
                        }
                        for word in getattr(segment, "words", ())
                        if word.word.strip()
                    ],
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
        return TranscriptionResult(text=joined, segments=collected, peaks=peaks)


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
