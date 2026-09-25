# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whisper weight store: inventory, atomic install, delete.

faster-whisper downloads weights into ``<data_dir>/models`` as a
HuggingFace cache tree
(``models--Systran--faster-whisper-<name>/snapshots/<rev>/model.bin``).
Until this module existed that download happened lazily inside the FIRST
transcription: a multi-GB stall with no progress anywhere and no way to
choose, pre-fetch, or remove a model.

Shape mirrors ``summarizer_env`` deliberately (the AI-summaries install
wizard), because the client reuses that wizard's contract:

1. Everything lands under ``<data_dir>/models/.install-<name>.tmp``.
2. The published tree is verified (``model.bin`` must exist) BEFORE it is
   moved into place — a truncated download or an HTML error page must never
   read as installed.
3. Only then is the tmp tree renamed onto the final path, so a failed
   install leaves NO partial directory and a pre-existing install survives
   a failed re-install.

Progress is ``{phase, percent, detail, model}`` with phases
``idle|downloading|verifying|done|failed`` — the summaries progress
contract plus the model name, since the client shows which download is
running.

The downloader is injectable: tests pass a fake, so no test ever pulls
3 GB. ``default_downloader`` calls faster-whisper's own loader.
"""

from __future__ import annotations

import os
import shutil
import threading
from collections.abc import Callable
from pathlib import Path

from app.config import get_settings
from app.logging_config import get_logger
from app.services.storage import MODELS_BY_ACCURACY, is_supported_model

log = get_logger(__name__)

#: Approximate download sizes, for the client's confirm copy ("~3.1 GB").
#: APPROXIMATE BY DESIGN: the real CT2 repos drift by a few MB between
#: revisions and the number exists to set expectations before a multi-GB
#: download, not to be asserted against the bytes that land on disk (the
#: installed size is reported separately, measured).
APPROX_DOWNLOAD_BYTES: dict[str, int] = {
    "large-v3": 3_100_000_000,
    "medium": 1_500_000_000,
    "small": 484_000_000,
    "base": 145_000_000,
    "tiny": 75_000_000,
}

#: The HF repo-dir prefix faster-whisper's Systran models land under.
_REPO_PREFIX = "models--Systran--faster-whisper-"

_IDLE = {"phase": "idle", "percent": 0, "detail": "", "model": ""}


class InstallError(Exception):
    """An install failed. Nothing was published; the tmp tree is gone."""


class InstallInProgress(Exception):  # noqa: N818
    """An install is already running; concurrent attempts are rejected."""


# --- module state -----------------------------------------------------------

_state_lock = threading.Lock()
_progress: dict = dict(_IDLE)
#: Held for the whole duration of an install (and during a delete).
_install_mutex = threading.Lock()


def _reset_state_for_tests() -> None:
    """Reset progress + mutex. Test-only: assumes no install thread."""
    global _progress, _install_mutex
    with _state_lock:
        _progress = dict(_IDLE)
    _install_mutex = threading.Lock()


def _set_progress(phase: str, percent: int, detail: str, model: str) -> None:
    global _progress
    with _state_lock:
        _progress = {
            "phase": phase,
            "percent": percent,
            "detail": detail,
            "model": model,
        }


def progress() -> dict:
    """Current install progress: {phase, percent, detail, model}. Never blocks."""
    with _state_lock:
        return dict(_progress)


def install_running() -> bool:
    return _install_mutex.locked()


# --- paths ------------------------------------------------------------------


def models_dir() -> Path:
    """``<data_dir>/models`` — the download_root TranscriptionService uses."""
    return Path(get_settings().data_dir) / "models"


def model_dir(name: str) -> Path:
    """The published HF repo dir for ``name`` (may not exist)."""
    return models_dir() / f"{_REPO_PREFIX}{name}"


def tmp_install_dir(name: str) -> Path:
    """Where an in-flight install builds before it is published."""
    return models_dir() / f".install-{name}.tmp"


# --- inventory --------------------------------------------------------------


def _model_bin_paths(repo: Path) -> list[Path]:
    """Every path named ``model.bin`` inside a repo tree (symlinks included)."""
    if not repo.is_dir():
        return []
    found: list[Path] = []
    for dirpath, _dirnames, filenames in os.walk(repo):
        if "model.bin" in filenames:
            found.append(Path(dirpath) / "model.bin")
    return found


def _has_model_bin(repo: Path) -> bool:
    """True iff the repo tree carries a model.bin that RESOLVES to real bytes.

    Two failure shapes this rejects, both observed for real:

    - a directory alone (an interrupted download leaves blobs/refs behind);
    - a DANGLING symlink. huggingface_hub's xet-backed cache stores the
      large blob at the CACHE ROOT (``<root>/blobs/<xx>/<hash>``) and points
      the repo's snapshot at it, so a repo dir moved away from its cache
      root keeps a ``model.bin`` entry that ``os.walk`` happily lists while
      opening it raises ENOENT. Offering either in the picker hands the user
      a selection that cannot load.
    """
    return any(p.is_file() for p in _model_bin_paths(repo))


def is_installed(name: str) -> bool:
    return _has_model_bin(model_dir(name))


def size_bytes_on_disk(name: str) -> int:
    """Bytes this model occupies, 0 when absent.

    Follows the HF cache's snapshot symlinks back to the blobs, but counts
    each real file ONCE — a symlink and its target are the same bytes, and
    double-counting would report ~2x the true footprint.
    """
    repo = model_dir(name)
    if not repo.is_dir():
        return 0
    total = 0
    seen: set = set()
    for dirpath, _dirnames, filenames in os.walk(repo):
        for filename in filenames:
            path = Path(dirpath) / filename
            try:
                stat = path.stat()  # follows symlinks into blobs/
                key = (stat.st_dev, stat.st_ino)
                if key in seen:
                    continue
                seen.add(key)
                total += stat.st_size
            except OSError:
                continue
    return total


def inventory() -> list[dict]:
    """Every supported model in ACCURACY order, with install state.

    Accuracy order (never size or alphabetical) because the client renders
    this list directly and Jeff's copy rule leads with accuracy.
    """
    return [
        {
            "name": name,
            "installed": is_installed(name),
            "size_bytes_on_disk": size_bytes_on_disk(name),
            "approx_download_bytes": APPROX_DOWNLOAD_BYTES[name],
        }
        for name in MODELS_BY_ACCURACY
    ]


# --- install ----------------------------------------------------------------


def default_downloader(name: str, cache_dir: str) -> None:
    """Download ``name`` into ``cache_dir`` using faster-whisper's own loader.

    ``download_model`` is the exact code path ``WhisperModel(...)`` takes on
    a cache miss, so a model installed here is byte-for-byte what a lazy
    first-transcription load would have fetched.
    """
    from faster_whisper.utils import download_model

    download_model(name, cache_dir=cache_dir)


Downloader = Callable[[str, str], None]


def _verify_downloaded(tmp: Path, name: str) -> None:
    """The downloaded tree must contain real, RESOLVABLE weights.

    Verification runs inside the tmp cache root, where a snapshot's
    ``model.bin`` symlink still points at its blob — which is exactly why
    publication has to carry the shared blob store along (see ``_publish``).
    """
    if not _has_model_bin(_published_source(tmp, name)):
        raise RuntimeError(
            f"downloaded tree for {name!r} contains no usable model.bin "
            "(truncated download or an error page)"
        )


def _published_source(tmp: Path, name: str) -> Path:
    """The subtree inside tmp that becomes the final repo dir."""
    nested = tmp / f"{_REPO_PREFIX}{name}"
    return nested if nested.is_dir() else tmp


def _merge_into(src: Path, dst: Path) -> None:
    """Move ``src`` onto ``dst``, merging directories entry by entry.

    The HF cache's dedup stores (``blobs/``, ``xet/``) are CONTENT-ADDRESSED
    and shared across repos, so an entry already present at the destination
    is the same bytes and is simply dropped rather than overwritten.
    """
    if src.is_dir() and not src.is_symlink():
        dst.mkdir(parents=True, exist_ok=True)
        for child in src.iterdir():
            _merge_into(child, dst / child.name)
        return
    if dst.exists() or dst.is_symlink():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))


def _publish(tmp: Path, name: str) -> None:
    """Move a verified tmp cache root into the live models dir.

    The repo dir alone is NOT enough. huggingface_hub's xet-backed cache
    keeps the big blob in a store at the CACHE ROOT and points the repo's
    snapshot at it with a relative symlink, so publishing only
    ``models--Systran--faster-whisper-<name>/`` and deleting the tmp root
    leaves a model.bin that dangles — verified live, and the reason this
    function moves the sibling stores first and the repo dir last.
    """
    final = model_dir(name)
    repo_name = f"{_REPO_PREFIX}{name}"
    source = _published_source(tmp, name)

    # Shared stores first: the repo's symlinks must resolve the instant the
    # repo dir lands at its final path.
    if source != tmp:
        for entry in list(tmp.iterdir()):
            if entry.name == repo_name:
                continue
            _merge_into(entry, models_dir() / entry.name)

    if final.exists():
        shutil.rmtree(final)
    source.rename(final)

    # Fail LOUD if publication produced something unloadable: a future
    # hf_hub layout change must surface as a failed install, never as a
    # model that reads installed and dies at first transcription.
    if not _has_model_bin(final):
        shutil.rmtree(final, ignore_errors=True)
        raise RuntimeError(
            f"published weights for {name!r} do not resolve "
            "(cache layout changed; nothing was installed)"
        )


def _run_install(name: str, downloader: Downloader) -> None:
    """Download into tmp, verify, then atomically publish. Lock held."""
    tmp = tmp_install_dir(name)
    final = model_dir(name)
    phase = "downloading"
    try:
        models_dir().mkdir(parents=True, exist_ok=True)
        if tmp.exists():
            shutil.rmtree(tmp)
        tmp.mkdir(parents=True)

        _set_progress("downloading", 5, f"downloading {name} weights", name)
        downloader(name, str(tmp))

        phase = "verifying"
        _set_progress("verifying", 90, f"verifying {name} weights", name)
        _verify_downloaded(tmp, name)

        phase = "publishing"
        # Atomic publish: nothing exists at the final path until the whole
        # download has been verified. An existing install is replaced only
        # here, so a failed re-install never destroys working weights.
        _publish(tmp, name)
        shutil.rmtree(tmp, ignore_errors=True)
    except Exception as exc:
        shutil.rmtree(tmp, ignore_errors=True)
        _set_progress("failed", 0, f"{phase}: {exc}", name)
        log.warning(
            "transcription.model_install_failed",
            model=name,
            phase=phase,
            error=str(exc),
        )
        raise InstallError(f"{phase}: {exc}") from exc
    _set_progress("done", 100, f"{name} installed", name)
    log.info("transcription.model_installed", model=name)


def install(name: str, downloader: Downloader | None = None) -> None:
    """Install one model synchronously. Raises InstallInProgress on overlap."""
    if not is_supported_model(name):
        raise ValueError(f"unsupported model {name!r}")
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("a whisper model install is already running")
    try:
        _run_install(name, downloader or default_downloader)
    finally:
        _install_mutex.release()


def start_install(name: str, downloader: Downloader | None = None) -> threading.Thread:
    """Install one model in a background thread.

    The mutex is acquired *before* returning, so a concurrent start raises
    InstallInProgress immediately (409 at the API) with no thread-startup
    race — the summarizer_env.start_install contract.
    """
    if not is_supported_model(name):
        raise ValueError(f"unsupported model {name!r}")
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("a whisper model install is already running")
    _set_progress("downloading", 1, f"starting {name} download", name)

    def _worker() -> None:
        try:
            _run_install(name, downloader or default_downloader)
        except InstallError:
            pass  # progress already says 'failed'; nobody awaits this thread
        finally:
            _install_mutex.release()

    thread = threading.Thread(
        target=_worker, name=f"whisper-model-install-{name}", daemon=True
    )
    thread.start()
    return thread


# --- delete -----------------------------------------------------------------


def delete_model(name: str) -> bool:
    """Remove one model's weights. True when something was deleted.

    Raises InstallInProgress while an install is running: deleting under a
    live download is how you get a half-tree that reads as installed.
    """
    if not is_supported_model(name):
        raise ValueError(f"unsupported model {name!r}")
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("cannot delete while an install is running")
    try:
        repo = model_dir(name)
        existed = repo.exists()
        if existed:
            shutil.rmtree(repo, ignore_errors=True)
        tmp = tmp_install_dir(name)
        if tmp.exists():
            shutil.rmtree(tmp, ignore_errors=True)
        if existed:
            log.info("transcription.model_deleted", model=name)
        return existed
    finally:
        _install_mutex.release()
