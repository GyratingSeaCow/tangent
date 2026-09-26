# SPDX-License-Identifier: AGPL-3.0-or-later
"""AI-summaries worker: turns meeting transcripts into stored summaries.

Mirrors ``ocr_worker`` (the handwriting-search arc's worker): inference runs
in a PERSISTENT subprocess (``summarize_infer.py --serve``) under the
summarizer env's python — llama-cpp is never imported into the server
process, and the model is loaded once per child lifetime with JSON requests
streaming over stdin/stdout (the OCR arc measured 39s/line with a fresh
subprocess per request vs ~0.1s once loaded).

Per-dump failures are logged warnings that leave ``dumps.summary`` NULL —
never job-fatal, and never a partial write: the summary columns and the
change_log entry that announces them to sync commit in the SAME
transaction (pattern: ``ocr_worker._purge_notebook``).
"""

from __future__ import annotations

import collections
import json
import queue
import sqlite3
import subprocess
import threading
from collections.abc import Callable
from pathlib import Path

from app.logging_config import get_logger
from app.services import summarizer_env
from app.summarize_infer import MODEL_FILENAME
from app.summary_templates import assemble_prompt, default_template_id, get_custom_prompt

log = get_logger(__name__)

#: Per-request inference budget (seconds). Qwen 4B on CPU takes tens of
#: seconds for a long transcript; three minutes of silence means the env is
#: broken, not slow. The first request of a fresh child also pays the model
#: load inside this budget.
INFER_TIMEOUT_S = 180

#: What ``dumps.summary_model`` records: the exact GGUF stem.
MODEL_STEM = Path(MODEL_FILENAME).stem

#: app_settings key for the server-side summaries toggle. The toggle gates a
#: SERVER worker, so it persists server-side — not in a client's storage.
SETTINGS_KEY = "summaries_enabled"


# --- toggle -------------------------------------------------------------------


def summaries_enabled(db: sqlite3.Connection) -> bool:
    """The persisted auto-summarize toggle. Defaults to OFF (opt-in)."""
    row = db.execute(
        "SELECT value FROM app_settings WHERE key = ?", (SETTINGS_KEY,)
    ).fetchone()
    return row is not None and row[0] == "1"


def set_summaries_enabled(db: sqlite3.Connection, enabled: bool) -> None:
    db.execute(
        "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
        (SETTINGS_KEY, "1" if enabled else "0"),
    )
    db.commit()


# --- subprocess inference -----------------------------------------------------


def _infer_script() -> Path:
    """app/summarize_infer.py — the script the install verify step also runs."""
    return Path(__file__).resolve().parent.parent / "summarize_infer.py"


class _ChildFailure(Exception):  # noqa: N818 - transport failure, not an API error
    """The persistent child failed at the TRANSPORT level: died, hung past
    the deadline, or spoke a non-JSON line. Distinct from a child-reported
    ``{"error": ...}`` result, which is a healthy child rejecting one
    request (no restart for those)."""


class _InferChild:
    """One persistent ``summarize_infer.py --serve`` subprocess.

    A reader thread pumps stdout lines into a queue so requests can wait
    with a deadline; a second thread drains stderr into a bounded tail for
    error messages. ``closed`` marks a deliberate shutdown so the retry
    logic can tell stop_worker's kill apart from a crash — a killed child
    must NOT be respawned by an in-flight request.
    """

    def __init__(self, argv: list[str], env: dict | None = None) -> None:
        self.closed = False
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=env,
        )
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._stderr_tail: collections.deque[str] = collections.deque(maxlen=20)
        threading.Thread(
            target=self._pump_stdout, name="summarize-infer-stdout", daemon=True
        ).start()
        threading.Thread(
            target=self._pump_stderr, name="summarize-infer-stderr", daemon=True
        ).start()

    def _pump_stdout(self) -> None:
        try:
            for line in self.proc.stdout:  # type: ignore[union-attr]
                self._lines.put(line)
        except ValueError:
            pass  # pipe closed under the reader during shutdown
        self._lines.put(None)  # EOF sentinel: the child is gone

    def _pump_stderr(self) -> None:
        try:
            for line in self.proc.stderr:  # type: ignore[union-attr]
                self._stderr_tail.append(line)
        except ValueError:
            pass

    def _death_notice(self) -> str:
        try:
            rc: int | str = self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            rc = "?"
        tail = "".join(self._stderr_tail).strip()[-500:]
        return f"summarize_infer exited {rc}: {tail}"

    def request(
        self,
        dump_id: str,
        transcript: str,
        system_prompt: str,
        timeout: float,
    ) -> str:
        """One transcript in, one summary out.

        Raises _ChildFailure on transport death/hang/garbage; RuntimeError
        on a child-reported per-request error (child stays up).
        """
        line_out = json.dumps(
            {
                "id": dump_id,
                "transcript": transcript,
                "system_prompt": system_prompt,
            }
        )
        try:
            self.proc.stdin.write(line_out + "\n")  # type: ignore[union-attr]
            self.proc.stdin.flush()  # type: ignore[union-attr]
        except (OSError, ValueError) as exc:
            raise _ChildFailure(self._death_notice()) from exc
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty:
            raise _ChildFailure(
                f"summarize_infer timed out after {timeout}s"
            ) from None
        if line is None:
            raise _ChildFailure(self._death_notice())
        try:
            result = json.loads(line)
        except ValueError as exc:
            raise _ChildFailure(
                f"summarize_infer spoke garbage: {line.strip()[:200]!r}"
            ) from exc
        if not isinstance(result, dict):
            raise _ChildFailure(
                f"summarize_infer sent a non-object: {line.strip()[:200]!r}"
            )
        if "summary" in result:
            return str(result["summary"]).strip()
        raise RuntimeError(str(result.get("error") or "unknown inference error"))

    def close(self) -> None:
        """Deliberate shutdown. Never hangs: EOF first (clean exit), then a
        short grace, then kill — a child whose env was deleted under it (the
        uninstall quiesce path) dies here instead of lingering."""
        self.closed = True
        try:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                log.warning("summarizer_worker.infer_child_unkillable")


#: Guards the child REFERENCE (brief holds only — never held across a
#: request, so stop_worker can always grab it to kill a hung child).
_child_lock = threading.Lock()
#: Serializes whole inference calls: one in-flight request at a time.
_infer_serial = threading.Lock()
_infer_child: _InferChild | None = None


def _spawn_child() -> _InferChild:
    py = summarizer_env.python_path()
    if py is None:
        raise RuntimeError("summarizer environment is not installed")
    try:
        # child_env: the SAME environment the installer's selftest verified
        # (LD_LIBRARY_PATH → the venv's vendored CUDA libs, when present).
        return _InferChild(
            [py, str(_infer_script()), "--serve"], env=summarizer_env.child_env(py)
        )
    except OSError as exc:
        raise RuntimeError(
            f"failed to start summarize_infer --serve: {exc}"
        ) from exc


def _ensure_child() -> _InferChild:
    global _infer_child
    with _child_lock:
        if _infer_child is None:
            _infer_child = _spawn_child()
        return _infer_child


def _discard_child(child: _InferChild) -> None:
    global _infer_child
    with _child_lock:
        if _infer_child is child:
            _infer_child = None
    child.close()


def shutdown_infer_child() -> None:
    """Kill the persistent inference child, if any. Part of every stop path."""
    global _infer_child
    with _child_lock:
        child, _infer_child = _infer_child, None
    if child is not None:
        child.close()


def run_inference(dump_id: str, transcript: str, system_prompt: str) -> str:
    """Summarize one transcript via the persistent child, restarting it ONCE
    on transport failure (crash/timeout/garbage) before surfacing the error.
    Raises RuntimeError on failure."""
    if summarizer_env.python_path() is None:
        raise RuntimeError("summarizer environment is not installed")
    with _infer_serial:
        child = _ensure_child()
        try:
            return child.request(dump_id, transcript, system_prompt, INFER_TIMEOUT_S)
        except _ChildFailure as exc:
            deliberate = child.closed
            _discard_child(child)
            if deliberate:
                # stop_worker killed it under us: surface, never respawn.
                raise RuntimeError(str(exc)) from exc
            log.warning("summarizer_worker.infer_restarted", error=str(exc))
            retry = _ensure_child()
            try:
                return retry.request(
                    dump_id, transcript, system_prompt, INFER_TIMEOUT_S
                )
            except _ChildFailure as exc2:
                _discard_child(retry)
                raise RuntimeError(str(exc2)) from exc2


Infer = Callable[[str, str, str], str]


# --- summarizing one dump -----------------------------------------------------


def summarize_dump(
    db: sqlite3.Connection,
    dump_id: str,
    infer: Infer = run_inference,
    now: int | None = None,
) -> bool:
    """Summarize one dump and persist the result. Returns True on success.

    Idempotent replace: an existing summary is overwritten. A failure is a
    logged WARNING that leaves ``summary`` NULL (or the previous value) —
    never job-fatal, and never a partial write: the three summary columns
    and the change_log entry commit in the SAME transaction, so a crash
    between them cannot strand a summary no device is ever told about.
    """
    import time as _time

    if now is None:
        now = int(_time.time())

    row = db.execute(
        "SELECT transcript, mode, summary_template, deleted_at "
        "FROM dumps WHERE id = ?",
        (dump_id,),
    ).fetchone()
    if row is None or row["deleted_at"] is not None:
        log.info("summarizer_worker.dump_gone", dump_id=dump_id)
        return False
    transcript = row["transcript"]
    if not transcript or not transcript.strip():
        log.warning("summarizer_worker.no_transcript", dump_id=dump_id)
        return False

    template_id = row["summary_template"] or default_template_id(row["mode"])
    try:
        system_prompt = assemble_prompt(
            template_id,
            custom_prompt=get_custom_prompt(db),
        )
        summary = infer(dump_id, transcript, system_prompt)
    except Exception as exc:
        log.warning(
            "summarizer_worker.summarize_failed",
            dump_id=dump_id,
            error=str(exc),
        )
        return False
    if not summary:
        # A summary that postprocessed to nothing is a model failure, not a
        # result — storing '' would render an empty block on every device.
        log.warning("summarizer_worker.empty_summary", dump_id=dump_id)
        return False

    try:
        db.execute(
            "UPDATE dumps SET summary = ?, summary_model = ?, "
            "summarized_at = ?, updated_at = ? WHERE id = ?",
            (summary, MODEL_STEM, now, now, dump_id),
        )
        # Announce to the sync feed IN THE SAME TRANSACTION as the column
        # write: one commit covers both, so devices either see a dump whose
        # payload carries the summary or nothing changed at all.
        from app.api.dumps import _publish_dump_change

        _publish_dump_change(db, dump_id, None)
        db.commit()
    except Exception:
        db.rollback()
        log.exception("summarizer_worker.persist_failed", dump_id=dump_id)
        return False
    log.info("summarizer_worker.summarized", dump_id=dump_id, chars=len(summary))
    return True


# --- queue + worker thread ----------------------------------------------------

_lock = threading.Lock()
_queue: list[str] = []
_queued: set[str] = set()
_wake = threading.Event()
_stop = threading.Event()
_thread: threading.Thread | None = None


def enqueue(dump_id: str) -> None:
    """Queue a dump for summarization. Deduplicates while pending."""
    with _lock:
        if dump_id not in _queued:
            _queue.append(dump_id)
            _queued.add(dump_id)
    _wake.set()


def pending() -> list[str]:
    with _lock:
        return list(_queue)


def clear_queue() -> None:
    """Drop every pending dump. Used by uninstall: entries queued for a
    deleted env would only ever fail against a missing python."""
    with _lock:
        _queue.clear()
        _queued.clear()
        _wake.clear()


def _pop() -> str | None:
    with _lock:
        if not _queue:
            _wake.clear()
            return None
        dump_id = _queue.pop(0)
        _queued.discard(dump_id)
        return dump_id


def maybe_enqueue_auto(db: sqlite3.Connection, dump_id: str, mode: str) -> bool:
    """Auto-trigger, gated exactly per the spec: mode=meeting AND capability
    installed AND toggle enabled. Non-meeting dumps are regenerate-only."""
    if mode != "meeting":
        return False
    if summarizer_env.python_path() is None:
        return False
    if not summaries_enabled(db):
        return False
    enqueue(dump_id)
    start_worker_if_installed()
    return True


def _worker_loop() -> None:
    import contextlib

    from app.db import get_db

    while not _stop.is_set():
        dump_id = _pop()
        if dump_id is None:
            _wake.wait(timeout=0.5)
            continue
        gen = get_db()
        db = next(gen)
        try:
            summarize_dump(db, dump_id)
        except Exception:
            # One bad dump must not kill the worker thread.
            log.exception("summarizer_worker.summarize_crashed", dump_id=dump_id)
        finally:
            with contextlib.suppress(StopIteration):
                next(gen)


def worker_running() -> bool:
    return _thread is not None and _thread.is_alive()


def start_worker_if_installed() -> threading.Thread | None:
    """Start the summarize thread iff the env is installed and verified.

    Without the env there is nothing to infer with — the queue still accepts
    entries (they are processed after an install + restart or a later start).
    """
    global _thread
    if summarizer_env.python_path() is None:
        return None
    if worker_running():
        return _thread
    _stop.clear()
    _thread = threading.Thread(
        target=_worker_loop, name="summarizer-worker", daemon=True
    )
    _thread.start()
    log.info("summarizer_worker.started")
    return _thread


def stop_worker() -> None:
    """Stop the summarize thread AND the persistent inference child.

    The child kill runs even when the thread never started (tests and API
    paths call run_inference directly) — uninstall's quiesce-first contract
    requires no live child when the env dir is wiped right after.
    """
    global _thread
    if _thread is not None:
        _stop.set()
        _wake.set()
        _thread.join(timeout=5)
        _thread = None
        _stop.clear()
        _wake.clear()
    shutdown_infer_child()


def _reset_for_tests() -> None:
    """Stop the thread and drop all queue state. Test-only."""
    stop_worker()
    with _lock:
        _queue.clear()
        _queued.clear()
    _wake.clear()
    _stop.clear()
