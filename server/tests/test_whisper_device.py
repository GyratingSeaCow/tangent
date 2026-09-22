# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whisper device selection: the libcublas.so.12 regression.

The bug this guards against: device="auto" made faster-whisper pick CUDA
the moment docker-compose.gpu.yml made the GPU visible (added for OCR),
but ctranslate2 needs the CUDA 12 runtime (libcublas.so.12, cudnn 9) and
the image only carried torch's CUDA 13 wheels. Model LOAD succeeds (lazy);
the first real inference dies with 'Library libcublas.so.12 is not found'
— which surfaced on every device as a failed transcription.

Contract under test (resolve_whisper_device):
- auto + CUDA runtime actually loadable  -> cuda
- auto + runtime missing                 -> cpu (never crash later)
- TANGENT_WHISPER_DEVICE=cpu             -> cpu, no probe
- TANGENT_WHISPER_DEVICE=cuda            -> cuda even if probe says no
  (explicit opt-in is fail-loud by design: a misconfigured GPU box should
  error visibly, not silently transcribe on CPU forever)
"""

from __future__ import annotations

from unittest.mock import patch

from app.services.transcription import resolve_whisper_device


class TestResolveWhisperDevice:
    def test_auto_with_working_cuda_runtime_picks_cuda(self, monkeypatch):
        monkeypatch.delenv("TANGENT_WHISPER_DEVICE", raising=False)
        with patch(
            "app.services.transcription._cuda_runtime_loadable", return_value=True
        ):
            assert resolve_whisper_device() == "cuda"

    def test_auto_without_cuda_runtime_falls_back_to_cpu(self, monkeypatch):
        monkeypatch.delenv("TANGENT_WHISPER_DEVICE", raising=False)
        with patch(
            "app.services.transcription._cuda_runtime_loadable", return_value=False
        ):
            assert resolve_whisper_device() == "cpu"

    def test_explicit_cpu_skips_the_probe_entirely(self, monkeypatch):
        monkeypatch.setenv("TANGENT_WHISPER_DEVICE", "cpu")
        with patch(
            "app.services.transcription._cuda_runtime_loadable"
        ) as probe:
            assert resolve_whisper_device() == "cpu"
            probe.assert_not_called()

    def test_explicit_cuda_is_honored_even_if_probe_would_fail(self, monkeypatch):
        # Fail-loud on explicit opt-in: the operator said cuda, so a broken
        # runtime must surface as an error, not a silent CPU fallback.
        monkeypatch.setenv("TANGENT_WHISPER_DEVICE", "cuda")
        with patch(
            "app.services.transcription._cuda_runtime_loadable", return_value=False
        ):
            assert resolve_whisper_device() == "cuda"

    def test_this_host_resolves_without_crashing(self, monkeypatch):
        # The real probe must be safe to run anywhere (Windows dev box, CI,
        # container): no exception, and a definite answer.
        monkeypatch.delenv("TANGENT_WHISPER_DEVICE", raising=False)
        assert resolve_whisper_device() in ("cpu", "cuda")
