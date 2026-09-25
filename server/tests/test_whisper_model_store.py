# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.services.whisper_models — the on-disk weight store.

Nothing here downloads anything: the download step is injectable and the
fakes build the same HuggingFace-cache layout faster-whisper produces
(``models--Systran--faster-whisper-<name>/snapshots/<rev>/model.bin``).
"""

from __future__ import annotations

import shutil
import threading
import time
from pathlib import Path

import pytest

from app.services import whisper_models


@pytest.fixture(autouse=True)
def _reset_state():
    whisper_models._reset_state_for_tests()
    yield
    whisper_models._reset_state_for_tests()


def _make_repo(root: Path, name: str, *, model_bin: bool = True, size: int = 1234) -> Path:
    """Build a faster-whisper HF cache entry under ``root``."""
    repo = root / f"models--Systran--faster-whisper-{name}"
    snapshot = repo / "snapshots" / "deadbeef"
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / "config.json").write_bytes(b"{}")
    if model_bin:
        with open(snapshot / "model.bin", "wb") as f:
            f.truncate(size)
    return repo


def _make_xet_repo(root: Path, name: str, size: int = 4096) -> Path:
    """Build the layout huggingface_hub's XET cache really produces.

    Verified live against faster-whisper 1.2.1 / huggingface_hub: the big
    blob lives in a store at the CACHE ROOT (``<root>/blobs/<xx>/<hash>``,
    a SIBLING of the repo dir), the repo's own ``blobs/<hash>`` is a
    relative symlink into it, and the snapshot symlinks to that. Publishing
    the repo dir alone therefore leaves ``model.bin`` dangling.
    """
    repo = root / f"models--Systran--faster-whisper-{name}"
    snapshot = repo / "snapshots" / "deadbeef"
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / "config.json").write_bytes(b"{}")

    root_store = root / "blobs" / "95"
    root_store.mkdir(parents=True, exist_ok=True)
    real_blob = root_store / ("9" * 64)
    with open(real_blob, "wb") as f:
        f.truncate(size)

    repo_blobs = repo / "blobs"
    repo_blobs.mkdir(parents=True, exist_ok=True)
    repo_blob = repo_blobs / ("d" * 64)
    repo_blob.symlink_to(Path("..") / ".." / "blobs" / "95" / ("9" * 64))
    (snapshot / "model.bin").symlink_to(Path("..") / ".." / "blobs" / ("d" * 64))
    return repo


def _symlinks_work(tmp_path: Path) -> bool:
    """Windows needs Developer Mode / admin for symlinks; skip if unavailable."""
    probe = tmp_path / "_symlink_probe"
    try:
        probe.symlink_to(tmp_path)
    except (OSError, NotImplementedError):
        return False
    probe.unlink()
    return True


def fake_downloader(name: str, cache_dir: str) -> None:
    """Stand-in for faster-whisper's download_model: writes the real layout."""
    _make_repo(Path(cache_dir), name)


def _wait_not_running(timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while whisper_models.install_running() and time.time() < deadline:
        time.sleep(0.01)
    assert not whisper_models.install_running(), "install never finished"


# ---------------------------------------------------------------------------
# inventory: installed / sizes / approx table
# ---------------------------------------------------------------------------


class TestInventory:
    def test_missing_directory_is_not_installed(self, temp_data_dir):
        assert whisper_models.is_installed("small") is False
        assert whisper_models.size_bytes_on_disk("small") == 0

    def test_directory_with_model_bin_is_installed(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "small")
        assert whisper_models.is_installed("small") is True

    def test_partial_download_without_model_bin_is_not_installed(self, temp_data_dir):
        """A dir left behind by an interrupted download must read as NOT
        installed — otherwise the picker offers a model that cannot load."""
        _make_repo(whisper_models.models_dir(), "medium", model_bin=False)
        assert whisper_models.model_dir("medium").is_dir()
        assert whisper_models.is_installed("medium") is False

    def test_size_on_disk_sums_the_repo_directory(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "base", size=4096)
        size = whisper_models.size_bytes_on_disk("base")
        assert size >= 4096
        # Only THIS model's bytes: a neighbour must not inflate the number.
        _make_repo(whisper_models.models_dir(), "tiny", size=999_000)
        assert whisper_models.size_bytes_on_disk("base") == size

    def test_approx_download_bytes_covers_every_supported_model(self):
        from app.services.storage import SUPPORTED_MODELS

        assert set(whisper_models.APPROX_DOWNLOAD_BYTES) == set(SUPPORTED_MODELS)
        # Documented magnitudes from the spec (approximate, for confirm copy).
        assert whisper_models.APPROX_DOWNLOAD_BYTES["large-v3"] > 3_000_000_000
        assert whisper_models.APPROX_DOWNLOAD_BYTES["tiny"] < 100_000_000

    def test_approx_sizes_increase_with_accuracy(self):
        from app.services.storage import MODELS_BY_ACCURACY

        sizes = [whisper_models.APPROX_DOWNLOAD_BYTES[m] for m in MODELS_BY_ACCURACY]
        assert sizes == sorted(sizes, reverse=True)

    def test_inventory_is_in_accuracy_order_with_installed_flags(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "tiny", size=2048)
        rows = whisper_models.inventory()
        assert [r["name"] for r in rows] == ["large-v3", "medium", "small", "base", "tiny"]
        by_name = {r["name"]: r for r in rows}
        assert by_name["tiny"]["installed"] is True
        assert by_name["tiny"]["size_bytes_on_disk"] >= 2048
        assert by_name["large-v3"]["installed"] is False
        assert by_name["large-v3"]["size_bytes_on_disk"] == 0
        assert by_name["large-v3"]["approx_download_bytes"] == (
            whisper_models.APPROX_DOWNLOAD_BYTES["large-v3"]
        )


# ---------------------------------------------------------------------------
# install: progress contract + atomicity
# ---------------------------------------------------------------------------


class TestInstall:
    def test_progress_starts_idle(self, temp_data_dir):
        assert whisper_models.progress() == {
            "phase": "idle",
            "percent": 0,
            "detail": "",
            "model": "",
        }

    def test_install_publishes_the_model_and_reaches_done(self, temp_data_dir):
        whisper_models.install("small", downloader=fake_downloader)

        assert whisper_models.is_installed("small") is True
        prog = whisper_models.progress()
        assert prog["phase"] == "done"
        assert prog["percent"] == 100
        assert prog["model"] == "small"

    def test_install_phases_are_downloading_then_verifying_then_done(self, temp_data_dir):
        seen: list[str] = []

        def recording(name: str, cache_dir: str) -> None:
            seen.append(whisper_models.progress()["phase"])
            fake_downloader(name, cache_dir)

        whisper_models.install("base", downloader=recording)

        assert seen == ["downloading"]
        assert whisper_models.progress()["phase"] == "done"

    def test_percent_increases_across_the_install(self, temp_data_dir):
        percents: list[int] = []

        def recording(name: str, cache_dir: str) -> None:
            percents.append(whisper_models.progress()["percent"])
            fake_downloader(name, cache_dir)

        whisper_models.install("base", downloader=recording)
        percents.append(whisper_models.progress()["percent"])
        assert all(b > a for a, b in zip(percents, percents[1:], strict=False)), percents

    def test_final_dir_never_appears_mid_install(self, temp_data_dir):
        seen: list[bool] = []

        def recording(name: str, cache_dir: str) -> None:
            seen.append(whisper_models.model_dir(name).exists())
            fake_downloader(name, cache_dir)

        whisper_models.install("small", downloader=recording)
        assert seen == [False], "weights must be published atomically, not streamed in"

    def test_failed_download_leaves_no_partial_dir(self, temp_data_dir):
        """Requirement 5's atomicity clause: a failed install leaves NOTHING
        at the final path, so `installed` cannot lie afterwards."""

        def exploding(name: str, cache_dir: str) -> None:
            _make_repo(Path(cache_dir), name, model_bin=False)  # half a download
            raise RuntimeError("connection reset")

        with pytest.raises(whisper_models.InstallError):
            whisper_models.install("medium", downloader=exploding)

        assert not whisper_models.model_dir("medium").exists()
        assert not whisper_models.tmp_install_dir("medium").exists()
        assert whisper_models.is_installed("medium") is False
        prog = whisper_models.progress()
        assert prog["phase"] == "failed"
        assert "connection reset" in prog["detail"]
        assert prog["model"] == "medium"
        assert not whisper_models.install_running()

    def test_download_that_produces_no_model_bin_fails_verification(self, temp_data_dir):
        """A 'successful' download with no weights (HTML error page, truncated
        repo) must fail at verify and publish nothing."""

        def empty(name: str, cache_dir: str) -> None:
            _make_repo(Path(cache_dir), name, model_bin=False)

        with pytest.raises(whisper_models.InstallError):
            whisper_models.install("small", downloader=empty)

        assert not whisper_models.model_dir("small").exists()
        assert whisper_models.progress()["phase"] == "failed"
        assert "verify" in whisper_models.progress()["detail"]

    def test_reinstall_replaces_an_existing_install(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "small", size=10)
        whisper_models.install("small", downloader=fake_downloader)
        assert whisper_models.is_installed("small") is True
        assert whisper_models.size_bytes_on_disk("small") >= 1234

    def test_unsupported_model_is_rejected(self, temp_data_dir):
        with pytest.raises(ValueError):
            whisper_models.install("whisper-9000", downloader=fake_downloader)

    def test_xet_cache_layout_publishes_resolvable_weights(self, temp_data_dir, tmp_path):
        """REGRESSION (found by a live faster-whisper download, not a fake):

        huggingface_hub's xet cache writes the big blob to a store at the
        CACHE ROOT and symlinks the repo's snapshot at it. Publishing only
        ``models--Systran--faster-whisper-<name>/`` and deleting the tmp
        root left a ``model.bin`` that os.walk listed and open() could not
        read — is_installed() said True and the first transcription would
        have died. The install must carry the shared store along.
        """
        if not _symlinks_work(tmp_path):
            pytest.skip("symlinks unavailable (Windows without Developer Mode)")

        def xet_downloader(name: str, cache_dir: str) -> None:
            _make_xet_repo(Path(cache_dir), name)

        whisper_models.install("small", downloader=xet_downloader)

        published = whisper_models.model_dir("small")
        model_bin = published / "snapshots" / "deadbeef" / "model.bin"
        assert model_bin.is_symlink(), "fixture must exercise the symlink path"
        assert model_bin.is_file(), "published model.bin must RESOLVE, not dangle"
        with open(model_bin, "rb") as f:
            assert f.read(1) == b"\x00"
        assert whisper_models.is_installed("small") is True
        assert whisper_models.size_bytes_on_disk("small") >= 4096

    def test_dangling_model_bin_does_not_count_as_installed(self, temp_data_dir, tmp_path):
        """The bug's other half: a model.bin symlink whose target is gone is
        NOT an install, however convincing the directory looks."""
        if not _symlinks_work(tmp_path):
            pytest.skip("symlinks unavailable (Windows without Developer Mode)")

        repo = _make_xet_repo(whisper_models.models_dir(), "medium")
        shutil.rmtree(whisper_models.models_dir() / "blobs")

        assert (repo / "snapshots" / "deadbeef" / "model.bin").is_symlink()
        assert whisper_models.is_installed("medium") is False

    def test_xet_download_that_never_resolves_fails_verification(
        self, temp_data_dir, tmp_path
    ):
        """A download whose blob store never materialised must fail at verify
        and publish nothing — the loud failure, not a silent bad install."""
        if not _symlinks_work(tmp_path):
            pytest.skip("symlinks unavailable (Windows without Developer Mode)")

        def broken(name: str, cache_dir: str) -> None:
            _make_xet_repo(Path(cache_dir), name)
            shutil.rmtree(Path(cache_dir) / "blobs")

        with pytest.raises(whisper_models.InstallError):
            whisper_models.install("base", downloader=broken)

        assert not whisper_models.model_dir("base").exists()
        assert whisper_models.progress()["phase"] == "failed"

    def test_concurrent_install_raises_install_in_progress(self, temp_data_dir):
        release = threading.Event()

        def blocking(name: str, cache_dir: str) -> None:
            assert release.wait(timeout=10), "test never released the blocked download"
            fake_downloader(name, cache_dir)

        whisper_models.start_install("small", downloader=blocking)
        try:
            with pytest.raises(whisper_models.InstallInProgress):
                whisper_models.start_install("base", downloader=fake_downloader)
        finally:
            release.set()
        _wait_not_running()
        assert whisper_models.is_installed("small") is True

    def test_start_install_runs_in_the_background(self, temp_data_dir):
        whisper_models.start_install("tiny", downloader=fake_downloader)
        _wait_not_running()
        assert whisper_models.progress()["phase"] == "done"
        assert whisper_models.is_installed("tiny") is True


# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------


class TestDelete:
    def test_delete_removes_the_weights(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "small")
        assert whisper_models.delete_model("small") is True
        assert not whisper_models.model_dir("small").exists()
        assert whisper_models.is_installed("small") is False

    def test_delete_of_a_missing_model_is_false_not_an_error(self, temp_data_dir):
        assert whisper_models.delete_model("base") is False

    def test_delete_leaves_other_models_alone(self, temp_data_dir):
        _make_repo(whisper_models.models_dir(), "small")
        _make_repo(whisper_models.models_dir(), "tiny")
        whisper_models.delete_model("small")
        assert whisper_models.is_installed("tiny") is True

    def test_delete_during_an_install_raises(self, temp_data_dir):
        release = threading.Event()

        def blocking(name: str, cache_dir: str) -> None:
            assert release.wait(timeout=10)
            fake_downloader(name, cache_dir)

        whisper_models.start_install("small", downloader=blocking)
        try:
            with pytest.raises(whisper_models.InstallInProgress):
                whisper_models.delete_model("tiny")
        finally:
            release.set()
        _wait_not_running()

    def test_delete_rejects_an_unsupported_name(self, temp_data_dir):
        with pytest.raises(ValueError):
            whisper_models.delete_model("whisper-9000")
