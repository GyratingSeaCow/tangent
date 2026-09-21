# SPDX-License-Identifier: AGPL-3.0-or-later
"""On-demand OCR environment install manager.

The base container ships without torch/transformers — the handwriting-search
feature installs them into ``<data_dir>/ocr-env`` only when the user enables
it from the app. Install strategy:

1. Everything is built under ``<data_dir>/ocr-env.tmp``.
2. The last step runs the venv's python against ``app/ocr_infer.py --selftest``
   (Task 3's file; the hook is injectable so tests fake it).
3. Only after the self-test passes is the tmp dir atomically renamed to
   ``<data_dir>/ocr-env``. A failed install therefore leaves NO ocr-env dir
   (a pre-existing verified env from an earlier install is never destroyed by
   a failed re-install — it is only replaced at rename time).

Both flavours use the same model (``microsoft/trocr-base-handwritten``, per
the Task 0 bake-off ruling: base everywhere); they differ only in which torch
wheel index is used (cu128 vs cpu).

The step *runner* is injectable: tests pass a fake so no real pip installs or
model downloads happen. ``default_runner`` executes steps for real.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from app.config import get_settings
from app.logging_config import get_logger

log = get_logger(__name__)

MODEL_ID = "microsoft/trocr-base-handwritten"
FLAVOURS = ("gpu", "cpu")
TORCH_INDEX = {
    "gpu": "https://download.pytorch.org/whl/cu128",
    "cpu": "https://download.pytorch.org/whl/cpu",
}
# transformers 5.x breaks TrOCR tokenizer loading — the <5 pin is mandatory.
PYTHON_DEPS = (
    "transformers>=4.46,<5",
    "pillow",
    "sentencepiece",
    "protobuf",
    "huggingface_hub",
)

_IDLE = {"phase": "idle", "percent": 0, "detail": ""}


class InstallError(Exception):
    """An install step failed. The env dir was rolled back."""


class InstallInProgress(Exception):  # noqa: N818
    """An install is already running; concurrent attempts are rejected."""


@dataclass(frozen=True)
class InstallStep:
    """One unit of install work handed to the runner.

    kind: 'venv' (create virtualenv), 'pip' (install packages),
    'download' (snapshot_download of repo_id into dest), 'run' (subprocess).
    """

    phase: str
    kind: str
    argv: tuple[str, ...] = ()
    dest: str = ""
    repo_id: str = ""
    detail: str = ""
    percent: int = field(default=0, compare=False)


# --- module state -----------------------------------------------------------

_state_lock = threading.Lock()
_progress: dict = dict(_IDLE)
# Held for the whole duration of an install (and during uninstall).
_install_mutex = threading.Lock()


def _reset_state_for_tests() -> None:
    """Reset progress + mutex. Test-only: assumes no install thread is live."""
    global _progress, _install_mutex
    with _state_lock:
        _progress = dict(_IDLE)
    _install_mutex = threading.Lock()


def _set_progress(phase: str, percent: int, detail: str) -> None:
    global _progress
    with _state_lock:
        _progress = {"phase": phase, "percent": percent, "detail": detail}


def progress() -> dict:
    """Current install progress: {phase, percent, detail}. Never blocks."""
    with _state_lock:
        return dict(_progress)


def install_running() -> bool:
    return _install_mutex.locked()


# --- paths ------------------------------------------------------------------


def _base_dir() -> Path:
    """The server data dir (/data in the container, tmp_path in tests)."""
    return Path(get_settings().data_dir)


def env_dir() -> Path:
    return _base_dir() / "ocr-env"


def tmp_env_dir() -> Path:
    return _base_dir() / "ocr-env.tmp"


def _venv_python(base: Path) -> Path:
    """The venv interpreter under ``base/venv`` (Windows or POSIX layout)."""
    win = base / "venv" / "Scripts" / "python.exe"
    posix = base / "venv" / "bin" / "python"
    return win if win.exists() or sys.platform == "win32" else posix


def _ocr_infer_path() -> Path:
    """Task 3's inference script (app/ocr_infer.py). May not exist yet."""
    return Path(__file__).resolve().parent.parent / "ocr_infer.py"


def _read_marker(base: Path) -> dict | None:
    marker = base / "verified.json"
    if not marker.is_file():
        return None
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def python_path() -> str | None:
    """The installed venv's python, or None unless installed AND verified."""
    base = env_dir()
    if _read_marker(base) is None:
        return None
    py = _venv_python(base)
    return str(py) if py.exists() else None


# --- capability -------------------------------------------------------------


def probe_gpu_visible() -> bool:
    """True iff ``nvidia-smi -L`` succeeds and lists at least one GPU."""
    try:
        proc = subprocess.run(
            ["nvidia-smi", "-L"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if proc.returncode != 0:
        return False
    return bool((proc.stdout or "").strip())


def _disk_free_bytes() -> int:
    path = _base_dir()
    while not path.exists():
        parent = path.parent
        if parent == path:
            break
        path = parent
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return 0


def capability() -> dict:
    """Install/GPU/disk state for the client's enable-OCR wizard."""
    marker = _read_marker(env_dir())
    flavour = marker.get("flavour") if marker else None
    return {
        "installed": marker is not None,
        "flavour": flavour if flavour in FLAVOURS else None,
        "gpu_visible": probe_gpu_visible(),
        "disk_free_bytes": _disk_free_bytes(),
        "install_running": install_running(),
    }


# --- install ----------------------------------------------------------------


def _build_steps(flavour: str, tmp: Path) -> list[InstallStep]:
    py = str(tmp / "venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python"))
    return [
        InstallStep(
            phase="venv",
            kind="venv",
            argv=(sys.executable, "-m", "venv", str(tmp / "venv")),
            dest=str(tmp / "venv"),
            detail="creating virtualenv",
            percent=5,
        ),
        InstallStep(
            phase="torch",
            kind="pip",
            argv=(py, "-m", "pip", "install", "torch", "--index-url", TORCH_INDEX[flavour]),
            detail=f"installing torch ({flavour})",
            percent=15,
        ),
        InstallStep(
            phase="transformers",
            kind="pip",
            argv=(py, "-m", "pip", "install", *PYTHON_DEPS),
            detail="installing transformers + friends",
            percent=45,
        ),
        InstallStep(
            phase="weights",
            kind="download",
            repo_id=MODEL_ID,
            dest=str(tmp / "models"),
            detail=f"downloading {MODEL_ID}",
            percent=60,
        ),
        InstallStep(
            phase="verify",
            kind="run",
            argv=(py, str(_ocr_infer_path()), "--selftest"),
            detail="running model self-test",
            percent=85,
        ),
    ]


def default_runner(step: InstallStep) -> None:
    """Execute a step for real. Raises on any failure."""
    if step.kind == "download":
        from huggingface_hub import snapshot_download

        # HF cache layout under <env>/models so ocr_infer's from_pretrained
        # (cache_dir=<env>/models) resolves offline.
        snapshot_download(repo_id=step.repo_id, cache_dir=step.dest)
        return
    proc = subprocess.run(list(step.argv), capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-500:]
        raise RuntimeError(f"{' '.join(step.argv)} exited {proc.returncode}: {tail}")


Runner = Callable[[InstallStep], None]


def _run_install(flavour: str, runner: Runner) -> None:
    """Build the env in tmp, verify, then atomically publish. Lock held."""
    tmp = tmp_env_dir()
    final = env_dir()
    phase = "venv"
    try:
        if tmp.exists():
            shutil.rmtree(tmp)
        tmp.mkdir(parents=True)
        for step in _build_steps(flavour, tmp):
            phase = step.phase
            _set_progress(step.phase, step.percent, step.detail)
            runner(step)
        (tmp / "verified.json").write_text(
            json.dumps({"flavour": flavour, "model": MODEL_ID}),
            encoding="utf-8",
        )
        # Atomic publish: nothing exists at the final path until the whole
        # env (self-test included) has succeeded.
        if final.exists():
            shutil.rmtree(final)
        tmp.rename(final)
        _set_progress("done", 100, "installed")
        log.info("ocr_env.installed", flavour=flavour)
    except Exception as exc:
        shutil.rmtree(tmp, ignore_errors=True)
        _set_progress("failed", 0, f"{phase}: {exc}")
        log.warning("ocr_env.install_failed", phase=phase, error=str(exc))
        raise InstallError(f"{phase}: {exc}") from exc


def _validate_flavour(flavour: str) -> str:
    if flavour not in FLAVOURS:
        raise ValueError(f"flavour must be one of {FLAVOURS}, got {flavour!r}")
    return flavour


def install(flavour: str, runner: Runner | None = None) -> None:
    """Run a full install synchronously. Raises InstallInProgress on overlap."""
    _validate_flavour(flavour)
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("an OCR env install is already running")
    try:
        _run_install(flavour, runner or default_runner)
    finally:
        _install_mutex.release()


def start_install(flavour: str, runner: Runner | None = None) -> threading.Thread:
    """Run an install in a background thread.

    The install mutex is acquired *before* returning, so a concurrent
    start_install/install raises InstallInProgress immediately (409 at the
    API) with no thread-startup race.
    """
    _validate_flavour(flavour)
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("an OCR env install is already running")
    _set_progress("venv", 1, "starting install")

    def _worker() -> None:
        try:
            _run_install(flavour, runner or default_runner)
        except InstallError:
            pass  # progress already says 'failed'; nobody is awaiting this thread
        finally:
            _install_mutex.release()

    thread = threading.Thread(target=_worker, name="ocr-env-install", daemon=True)
    thread.start()
    return thread


# --- uninstall --------------------------------------------------------------


def uninstall(db) -> bool:
    """Delete the venv + weights and drop indexed OCR text.

    Raises InstallInProgress if an install is currently running.
    """
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("cannot uninstall while an install is running")
    try:
        for path in (env_dir(), tmp_env_dir()):
            if path.exists():
                shutil.rmtree(path)
        # Task 3 owns the ink_index schema; on a server that never ran the
        # OCR worker the table does not exist, so delete conditionally.
        row = db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ink_index'"
        ).fetchone()
        if row is not None:
            db.execute("DELETE FROM ink_index")
        db.commit()
        _set_progress("idle", 0, "")
        log.info("ocr_env.uninstalled")
        return True
    finally:
        _install_mutex.release()
