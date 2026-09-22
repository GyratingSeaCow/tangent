# SPDX-License-Identifier: AGPL-3.0-or-later
"""OCR index worker: turns notebook ink into searchable ink_index rows.

The pipeline per notebook: segment strokes into Lines of Words (Task 1),
diff ``line_id``s against the rows already indexed — a line_id is the sha1 of
its member stroke ids, so ANY stroke edit yields a new id and an untouched
line keeps its rows byte-for-byte — render only the changed lines (Task 1),
hand each image to ``infer`` (the real one shells to the on-demand OCR venv,
tests inject a lambda), split the returned text across the line's Words in
x-order, and publish ONE ink_index change per notebook batch so devices know
to re-pull the replace-set.

Inference runs in a SUBPROCESS via ``ocr_env.python_path()``: torch and
transformers are never imported into the server process.
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import tempfile
import threading
from collections.abc import Callable
from pathlib import Path

from PIL import Image

from app.logging_config import get_logger
from app.services import ocr_env
from app.services.change_log import record_change
from app.services.ink_render import render_line
from app.services.ink_segmentation import Line, segment_ink

log = get_logger(__name__)

#: Per-line inference budget. TrOCR-base on CPU takes seconds; a minute of
#: silence means the venv is broken, not slow.
INFER_TIMEOUT_S = 120


# --- subprocess inference ---------------------------------------------------


def _infer_script() -> Path:
    """app/ocr_infer.py — the script the install verify step also runs."""
    return Path(__file__).resolve().parent.parent / "ocr_infer.py"


def run_inference(image: Image.Image) -> str:
    """OCR one line image via the installed venv's python. Raises on failure."""
    py = ocr_env.python_path()
    if py is None:
        raise RuntimeError("OCR environment is not installed")

    # delete=False + manual unlink: on Windows an open NamedTemporaryFile
    # cannot be reopened by the image save or the child process.
    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)  # noqa: SIM115
    try:
        tmp.close()
        image.save(tmp.name, format="PNG")
        argv = [py, str(_infer_script()), "--image", tmp.name]
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=INFER_TIMEOUT_S
        )
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip()[-500:]
            raise RuntimeError(
                f"ocr_infer exited {proc.returncode}: {tail}"
            )
        return (proc.stdout or "").strip()
    finally:
        Path(tmp.name).unlink(missing_ok=True)


Infer = Callable[[Image.Image], str]


# --- indexing ---------------------------------------------------------------


def _split_across_words(text: str, n: int) -> list[str]:
    """Distribute whitespace tokens across ``n`` word slots, left to right.

    Fewer tokens than words leaves the trailing slots empty; extra tokens
    pile into the last slot — the geometry chose n boxes, the model's word
    count is advisory.
    """
    tokens = text.split()
    if n <= 0:
        return []
    if len(tokens) <= n:
        return tokens + [""] * (n - len(tokens))
    return tokens[: n - 1] + [" ".join(tokens[n - 1 :])]


def _index_line(
    db: sqlite3.Connection,
    notebook_id: str,
    line: Line,
    strokes: list[dict],
    infer: Infer,
    now: int,
) -> None:
    """Render + infer one line and write its word rows.

    A failure (render_line's ValueError on unknown ids, or the model
    exploding) is recorded as error rows for THIS line only — never
    job-fatal, and the recorded line_id stops a hot retry loop; the line is
    retried when its strokes next change.
    """
    # x-order is authoritative for text assignment: the model reads left to
    # right, so the leftmost box gets the first token.
    words = sorted(line.words, key=lambda w: w.bbox[0])
    all_ids = [sid for w in words for sid in w.stroke_ids]
    try:
        image = render_line(strokes, all_ids)
        text = infer(image)
        texts = _split_across_words(text, len(words))
        model = ocr_env.MODEL_ID
    except Exception as exc:
        log.warning(
            "ocr_worker.line_failed",
            notebook_id=notebook_id,
            line_id=line.line_id,
            error=str(exc),
        )
        texts = [""] * len(words)
        model = "error"

    for i, (word, word_text) in enumerate(zip(words, texts, strict=True)):
        db.execute(
            "INSERT OR REPLACE INTO ink_index "
            "(id, notebook_id, line_id, word_text, word_text_lower, "
            " bbox_json, stroke_ids_json, model, indexed_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                f"{line.line_id}:{i:03d}",
                notebook_id,
                line.line_id,
                word_text,
                word_text.lower(),
                json.dumps(list(word.bbox)),
                json.dumps(word.stroke_ids),
                model,
                now,
            ),
        )


def _purge_notebook(db: sqlite3.Connection, notebook_id: str, now: int) -> None:
    """Drop a dead notebook's rows; publish a delete only if any existed."""
    cursor = db.execute(
        "DELETE FROM ink_index WHERE notebook_id = ?", (notebook_id,)
    )
    if cursor.rowcount:
        record_change(
            db,
            entity_type="ink_index",
            entity_id=notebook_id,
            op="delete",
            device_id="server",
            now=now,
        )


def reindex_notebook(
    db: sqlite3.Connection,
    notebook_id: str,
    infer: Infer = run_inference,
    now: int | None = None,
) -> None:
    """Bring one notebook's ink_index rows up to date. Line-granular.

    Unchanged lines are untouched (their ``indexed_at`` proves it); stale
    line rows are dropped; new lines are rendered and inferred. Exactly one
    change_log entry is published per batch that actually changed something —
    its payload is built fresh at pull time, so the entry is only a signal.
    """
    import time as _time

    if now is None:
        now = int(_time.time())

    row = db.execute(
        "SELECT ink, deleted_at FROM notebooks WHERE id = ?", (notebook_id,)
    ).fetchone()
    if row is None or row["deleted_at"] is not None:
        _purge_notebook(db, notebook_id, now)
        db.commit()
        return

    strokes: list[dict] = []
    if row["ink"]:
        try:
            ink = json.loads(row["ink"])
        except ValueError:
            ink = None
        if isinstance(ink, dict):
            strokes = ink.get("strokes") or []

    lines = segment_ink(strokes)
    current_ids = {line.line_id for line in lines}
    existing_ids = {
        r["line_id"] if isinstance(r, sqlite3.Row) else r[0]
        for r in db.execute(
            "SELECT DISTINCT line_id FROM ink_index WHERE notebook_id = ?",
            (notebook_id,),
        )
    }

    stale = existing_ids - current_ids
    fresh = [line for line in lines if line.line_id not in existing_ids]
    if not stale and not fresh:
        return  # nothing changed: no writes, no change_log noise

    if stale:
        placeholders = ",".join("?" * len(stale))
        db.execute(
            f"DELETE FROM ink_index WHERE notebook_id = ? "
            f"AND line_id IN ({placeholders})",
            (notebook_id, *sorted(stale)),
        )

    for line in fresh:
        _index_line(db, notebook_id, line, strokes, infer, now)

    record_change(
        db,
        entity_type="ink_index",
        entity_id=notebook_id,
        op="upsert",
        device_id="server",
        payload=None,  # rows are built fresh at pull time (replace-set)
        now=now,
    )
    db.commit()
    log.info(
        "ocr_worker.indexed",
        notebook_id=notebook_id,
        new_lines=len(fresh),
        stale_lines=len(stale),
    )


# --- queue + worker thread --------------------------------------------------

_lock = threading.Lock()
_queue: list[str] = []
_queued: set[str] = set()
_wake = threading.Event()
_stop = threading.Event()
_thread: threading.Thread | None = None


def enqueue(notebook_id: str) -> None:
    """Queue a notebook for (re)indexing. Deduplicates while pending."""
    with _lock:
        if notebook_id not in _queued:
            _queue.append(notebook_id)
            _queued.add(notebook_id)
    _wake.set()


def pending() -> list[str]:
    with _lock:
        return list(_queue)


def clear_queue() -> None:
    """Drop every pending notebook. Used by uninstall: entries queued for a
    deleted env would only ever produce all-error junk rows."""
    with _lock:
        _queue.clear()
        _queued.clear()
        _wake.clear()


def _pop() -> str | None:
    with _lock:
        if not _queue:
            _wake.clear()
            return None
        notebook_id = _queue.pop(0)
        _queued.discard(notebook_id)
        return notebook_id


def backfill_scan(db: sqlite3.Connection) -> list[str]:
    """Enqueue every live, inked notebook with no index rows at all.

    Runs on worker start so notebooks that synced while OCR was uninstalled
    (or before this feature existed) get indexed without waiting for their
    next edit.
    """
    rows = db.execute(
        """
        SELECT id FROM notebooks
        WHERE deleted_at IS NULL
          AND ink IS NOT NULL
          AND id NOT IN (SELECT DISTINCT notebook_id FROM ink_index)
        ORDER BY updated_at DESC
        """
    ).fetchall()
    found = [r["id"] if isinstance(r, sqlite3.Row) else r[0] for r in rows]
    for notebook_id in found:
        enqueue(notebook_id)
    return found


def _worker_loop() -> None:
    import contextlib

    from app.db import get_db

    gen = get_db()
    db = next(gen)
    try:
        backfill_scan(db)
    finally:
        with contextlib.suppress(StopIteration):
            next(gen)

    while not _stop.is_set():
        notebook_id = _pop()
        if notebook_id is None:
            _wake.wait(timeout=0.5)
            continue
        gen = get_db()
        db = next(gen)
        try:
            reindex_notebook(db, notebook_id)
        except Exception:
            # One bad notebook must not kill the worker thread.
            log.exception("ocr_worker.reindex_failed", notebook_id=notebook_id)
        finally:
            with contextlib.suppress(StopIteration):
                next(gen)


def worker_running() -> bool:
    return _thread is not None and _thread.is_alive()


def start_worker_if_installed() -> threading.Thread | None:
    """Start the index thread iff the OCR env is installed and verified.

    Without the env there is nothing to infer with — the queue still accepts
    entries (they are processed after an install + restart or a later start).
    """
    global _thread
    if ocr_env.python_path() is None:
        return None
    if worker_running():
        return _thread
    _stop.clear()
    _thread = threading.Thread(
        target=_worker_loop, name="ocr-index-worker", daemon=True
    )
    _thread.start()
    log.info("ocr_worker.started")
    return _thread


def stop_worker() -> None:
    global _thread
    if _thread is None:
        return
    _stop.set()
    _wake.set()
    _thread.join(timeout=5)
    _thread = None
    _stop.clear()
    _wake.clear()


def _reset_for_tests() -> None:
    """Stop the thread and drop all queue state. Test-only."""
    stop_worker()
    with _lock:
        _queue.clear()
        _queued.clear()
    _wake.clear()
    _stop.clear()
