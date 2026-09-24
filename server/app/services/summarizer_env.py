# SPDX-License-Identifier: AGPL-3.0-or-later
"""On-demand summarizer environment install manager.

The base container ships without llama-cpp — the AI-summaries feature
installs it into ``<data_dir>/summarizer-env`` only when the user enables it
from the app. Mirrors ``ocr_env`` (the handwriting-search arc's manager):

1. Everything is built under ``<data_dir>/summarizer-env.tmp``.
2. The weights step downloads the Qwen GGUF and verifies its size (a
   truncated download or an HTML error page saved as the file must never
   reach the self-test, let alone be published).
3. The last step runs the venv's python against
   ``app/summarize_infer.py --selftest`` (one real tiny inference).
4. Only after the self-test passes is the tmp dir atomically renamed to
   ``<data_dir>/summarizer-env``. A failed install therefore leaves NO env
   dir (a pre-existing verified env from an earlier install is never
   destroyed by a failed re-install — it is only replaced at rename time).

Runtime selection is automatic, not a caller-chosen flavour: when a GPU is
visible the installer first attempts the CUDA llama-cpp-python wheel and
falls back to the CPU wheel on ANY failure. CPU is the baseline and always
works in the stock container; accuracy is IDENTICAL either way (speed only).

The step *runner* is injectable: tests pass a fake so no real pip installs
or the ~2.5 GB model download happen. ``default_runner`` executes for real.
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
from app.summarize_infer import MODEL_FILENAME

log = get_logger(__name__)

# The official Qwen repo is 401-gated; bartowski mirrors the same GGUF.
GGUF_REPO_ID = "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF"
#: The Q4_K_M file is ~2.5 GB; anything under this is a truncated download.
MIN_MODEL_BYTES = 2_400_000_000

RUNTIMES = ("cuda", "cpu")
#: llama-cpp-python prebuilt wheel indexes (abetlen's official extra index).
CUDA_WHEEL_INDEX = "https://abetlen.github.io/llama-cpp-python/whl/cu124"
CPU_WHEEL_INDEX = "https://abetlen.github.io/llama-cpp-python/whl/cpu"
LLAMA_CPP_SPEC = "llama-cpp-python>=0.3,<0.4"

_IDLE = {"phase": "idle", "percent": 0, "detail": ""}


class InstallError(Exception):
    """An install step failed. The env dir was rolled back."""


class InstallInProgress(Exception):  # noqa: N818
    """An install is already running; concurrent attempts are rejected."""


@dataclass(frozen=True)
class InstallStep:
    """One unit of install work handed to the runner.

    kind: 'venv' (create virtualenv), 'pip' (install packages),
    'download' (hf_hub_download of filename from repo_id to dest),
    'run' (subprocess).
    """

    phase: str
    kind: str
    argv: tuple[str, ...] = ()
    dest: str = ""
    repo_id: str = ""
    filename: str = ""
    detail: str = ""
    percent: int = field(default=0, compare=False)


# --- module state -----------------------------------------------------------

_state_lock = threading.Lock()
_progress: dict = dict(_IDLE)
# Held for the whole duration of an install (and during uninstall).
_install_mutex = threading.Lock()

#: Fired after a successful install has been atomically published. Task 2's
#: main.py wiring points this at the summarizer worker's start hook so an
#: install completing on a LIVE server starts summarizing without a restart.
#: Injected rather than imported to avoid a worker<->env import cycle
#: (ocr_env precedent).
_on_installed: Callable[[], None] | None = None


def set_on_installed(callback: Callable[[], None] | None) -> None:
    """Register (or clear, with None) the install-success hook."""
    global _on_installed
    _on_installed = callback


def _fire_on_installed() -> None:
    """Run the hook, swallowing its errors: once the env dir is published the
    install HAS succeeded — a broken hook must not report otherwise."""
    callback = _on_installed
    if callback is None:
        return
    try:
        callback()
    except Exception:
        log.exception("summarizer_env.on_installed_hook_failed")


def _reset_state_for_tests() -> None:
    """Reset progress + mutex + hook. Test-only: assumes no install thread."""
    global _progress, _install_mutex, _on_installed
    with _state_lock:
        _progress = dict(_IDLE)
    _install_mutex = threading.Lock()
    _on_installed = None


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
    return _base_dir() / "summarizer-env"


def tmp_env_dir() -> Path:
    return _base_dir() / "summarizer-env.tmp"


def _venv_python(base: Path) -> Path:
    """The venv interpreter under ``base/venv`` (Windows or POSIX layout)."""
    win = base / "venv" / "Scripts" / "python.exe"
    posix = base / "venv" / "bin" / "python"
    return win if win.exists() or sys.platform == "win32" else posix


def _summarize_infer_path() -> Path:
    """The standalone inference script (app/summarize_infer.py)."""
    return Path(__file__).resolve().parent.parent / "summarize_infer.py"


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


def model_path() -> str | None:
    """The installed GGUF, or None unless installed AND verified."""
    base = env_dir()
    if _read_marker(base) is None:
        return None
    gguf = base / "models" / MODEL_FILENAME
    return str(gguf) if gguf.is_file() else None


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
    """Install/GPU/disk state for the client's enable-summaries wizard."""
    marker = _read_marker(env_dir())
    runtime = marker.get("runtime") if marker else None
    return {
        "installed": marker is not None,
        "runtime": runtime if runtime in RUNTIMES else None,
        "gpu_visible": probe_gpu_visible(),
        "disk_free_bytes": _disk_free_bytes(),
        "install_running": install_running(),
    }


# --- install ----------------------------------------------------------------


def _tmp_python(tmp: Path) -> str:
    return str(tmp / "venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python"))


def _venv_step(tmp: Path) -> InstallStep:
    return InstallStep(
        phase="venv",
        kind="venv",
        argv=(sys.executable, "-m", "venv", str(tmp / "venv")),
        dest=str(tmp / "venv"),
        detail="creating virtualenv",
        percent=5,
    )


def _runtime_step(tmp: Path, runtime: str) -> InstallStep:
    index = CUDA_WHEEL_INDEX if runtime == "cuda" else CPU_WHEEL_INDEX
    return InstallStep(
        phase="runtime",
        kind="pip",
        argv=(
            _tmp_python(tmp),
            "-m",
            "pip",
            "install",
            LLAMA_CPP_SPEC,
            "--extra-index-url",
            index,
        ),
        detail=f"installing llama.cpp runtime ({runtime})",
        percent=15 if runtime == "cuda" else 20,
    )


def _weights_step(tmp: Path) -> InstallStep:
    return InstallStep(
        phase="weights",
        kind="download",
        repo_id=GGUF_REPO_ID,
        filename=MODEL_FILENAME,
        dest=str(tmp / "models" / MODEL_FILENAME),
        detail=f"downloading {MODEL_FILENAME}",
        percent=35,
    )


def _verify_step(tmp: Path) -> InstallStep:
    return InstallStep(
        phase="verify",
        kind="run",
        argv=(
            _tmp_python(tmp),
            str(_summarize_infer_path()),
            "--selftest",
            "--model-path",
            str(tmp / "models" / MODEL_FILENAME),
        ),
        detail="running model self-test",
        percent=85,
    )


def default_runner(step: InstallStep) -> None:
    """Execute a step for real. Raises on any failure."""
    if step.kind == "download":
        from huggingface_hub import hf_hub_download

        dest = Path(step.dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Download into the tmp env's models dir; local_dir gives us the
        # exact final filename (no HF cache indirection to relocate).
        hf_hub_download(
            repo_id=step.repo_id,
            filename=step.filename,
            local_dir=str(dest.parent),
        )
        return
    proc = subprocess.run(list(step.argv), capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-500:]
        raise RuntimeError(f"{' '.join(step.argv)} exited {proc.returncode}: {tail}")


Runner = Callable[[InstallStep], None]


def _verify_weights_size(tmp: Path) -> None:
    """A GGUF under the floor is a truncated download or an error page —
    fail the weights phase before the self-test can load garbage."""
    gguf = tmp / "models" / MODEL_FILENAME
    size = gguf.stat().st_size if gguf.is_file() else 0
    if size < MIN_MODEL_BYTES:
        raise RuntimeError(
            f"downloaded model is {size} bytes, expected at least {MIN_MODEL_BYTES}"
        )


def _install_runtime(tmp: Path, runner: Runner) -> str:
    """Install llama-cpp: CUDA attempt first when a GPU is visible, CPU
    fallback on ANY failure. Returns the runtime that actually installed.
    Accuracy is identical either way — only speed differs."""
    if probe_gpu_visible():
        step = _runtime_step(tmp, "cuda")
        _set_progress(step.phase, step.percent, step.detail)
        try:
            runner(step)
            return "cuda"
        except Exception as exc:
            log.warning("summarizer_env.cuda_wheel_failed_falling_back", error=str(exc))
    step = _runtime_step(tmp, "cpu")
    _set_progress(step.phase, step.percent, step.detail)
    runner(step)
    return "cpu"


def _run_install(runner: Runner) -> None:
    """Build the env in tmp, verify, then atomically publish. Lock held."""
    tmp = tmp_env_dir()
    final = env_dir()
    phase = "venv"
    try:
        if tmp.exists():
            shutil.rmtree(tmp)
        tmp.mkdir(parents=True)

        step = _venv_step(tmp)
        _set_progress(step.phase, step.percent, step.detail)
        runner(step)

        phase = "runtime"
        runtime = _install_runtime(tmp, runner)

        phase = "weights"
        step = _weights_step(tmp)
        _set_progress(step.phase, step.percent, step.detail)
        runner(step)
        _verify_weights_size(tmp)

        phase = "verify"
        step = _verify_step(tmp)
        _set_progress(step.phase, step.percent, step.detail)
        runner(step)

        (tmp / "verified.json").write_text(
            json.dumps({"runtime": runtime, "model": MODEL_FILENAME}),
            encoding="utf-8",
        )
        # Atomic publish: nothing exists at the final path until the whole
        # env (self-test included) has succeeded.
        if final.exists():
            shutil.rmtree(final)
        tmp.rename(final)
    except Exception as exc:
        shutil.rmtree(tmp, ignore_errors=True)
        _set_progress("failed", 0, f"{phase}: {exc}")
        log.warning("summarizer_env.install_failed", phase=phase, error=str(exc))
        raise InstallError(f"{phase}: {exc}") from exc
    _set_progress("done", 100, "installed")
    log.info("summarizer_env.installed", runtime=runtime)
    # After the publish and the 'done' progress: the wizard polling progress
    # sees success, and the hook runs against a fully-installed env. A
    # failed install never reaches this line.
    _fire_on_installed()


def install(runner: Runner | None = None) -> None:
    """Run a full install synchronously. Raises InstallInProgress on overlap."""
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("a summarizer env install is already running")
    try:
        _run_install(runner or default_runner)
    finally:
        _install_mutex.release()


def start_install(runner: Runner | None = None) -> threading.Thread:
    """Run an install in a background thread.

    The install mutex is acquired *before* returning, so a concurrent
    start_install/install raises InstallInProgress immediately (409 at the
    API) with no thread-startup race.
    """
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("a summarizer env install is already running")
    _set_progress("venv", 1, "starting install")

    def _worker() -> None:
        try:
            _run_install(runner or default_runner)
        except InstallError:
            pass  # progress already says 'failed'; nobody is awaiting this thread
        finally:
            _install_mutex.release()

    thread = threading.Thread(target=_worker, name="summarizer-env-install", daemon=True)
    thread.start()
    return thread


# --- uninstall --------------------------------------------------------------


def uninstall() -> bool:
    """Delete the venv + weights. MUST NOT touch dumps.summary* columns —
    stored summaries are user data; uninstall removes only the ability to
    generate new ones (the wizard's promise). Takes no db handle so there is
    nothing it *could* delete.

    Raises InstallInProgress if an install is currently running.
    """
    if not _install_mutex.acquire(blocking=False):
        raise InstallInProgress("cannot uninstall while an install is running")
    try:
        for path in (env_dir(), tmp_env_dir()):
            if path.exists():
                shutil.rmtree(path)
        _set_progress("idle", 0, "")
        log.info("summarizer_env.uninstalled")
        return True
    finally:
        _install_mutex.release()
