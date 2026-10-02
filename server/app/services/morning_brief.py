# SPDX-License-Identifier: AGPL-3.0-or-later
"""v1.41 Morning Brief: one AI-written daily brief, cached per server-local day.

Spec: docs/design/2026-10-01-morning-brief.md (Jeff's decisions are final).

- Gate: the summarizer env is installed AND the AI-summaries toggle is on.
- Input is an AGGREGATE (yesterday's captures, today's due to-dos, pinned
  items), rendered as plain Markdown and sent through the SAME persistent
  summarizer child (``summarizer_worker.run_inference``, which spawns with
  ``summarizer_env.child_env``) — no new runtime, no new spawn path.
- A day with nothing in it never reaches the model: it gets an honest fixed
  line, so an empty morning can never be filled with invented content.
- Generated once per date by a scheduler thread at ~05:00 server-local
  (catching up on a later boot), idempotent per date; regenerated only on
  explicit request (POST /v1/morning-brief/generate).
- Every failure is logged and swallowed: the brief is additive and must never
  break transcription, summaries, or startup.
"""

from __future__ import annotations

import contextlib
import json
import re
import sqlite3
import threading
import time
from collections.abc import Callable
from datetime import date, datetime, timedelta

from app.logging_config import get_logger
from app.services import summarizer_env, summarizer_worker
from app.summary_templates import morning_brief_prompt

log = get_logger(__name__)

#: Server-local minute of day the brief becomes due (05:00).
GENERATE_AT_MINUTE = 5 * 60
#: Scheduler poll interval, and the back-off between failed attempts.
TICK_S = 60.0
RETRY_AFTER_S = 30 * 60
MAX_ATTEMPTS_PER_DAY = 3

#: Bounds that keep a heavy day inside the model's context.
MAX_CAPTURES = 40
MAX_ITEM_CHARS = 600
MAX_LIST_ITEMS = 30

#: Honest fixed text for a day with no input. Never sent to the model.
EMPTY_DAY_BRIEF = "Nothing was captured yesterday, and nothing is due today."
EMPTY_DAY_MODEL = "none"

Infer = Callable[[str, str, str], str]


# --- aggregate input ----------------------------------------------------------


def _local_day_bounds(day: date) -> tuple[int, int]:
    """[start, end) epoch seconds of ``day`` in server-local time."""
    start = datetime(day.year, day.month, day.day).astimezone()
    end = (start + timedelta(days=1)).astimezone()
    return int(start.timestamp()), int(end.timestamp())


def _clip(text: str, limit: int = MAX_ITEM_CHARS) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1].rstrip() + "…"


_MODE_LABEL = {"meeting": "meeting", "brain_dump": "brain dump", "text_note": "note"}


def _captures(db: sqlite3.Connection, day: date) -> list[str]:
    start, end = _local_day_bounds(day - timedelta(days=1))
    rows = db.execute(
        "SELECT title, mode, summary, transcript FROM dumps "
        "WHERE deleted_at IS NULL AND created_at >= ? AND created_at < ? "
        "ORDER BY created_at ASC LIMIT ?",
        (start, end, MAX_CAPTURES),
    ).fetchall()
    lines: list[str] = []
    for row in rows:
        title = (row["title"] or "").strip() or "Untitled"
        label = _MODE_LABEL.get(row["mode"], row["mode"])
        body = (row["summary"] or "").strip() or (row["transcript"] or "").strip()
        lines.append(
            f"- {_clip(title, 120)} ({label})" + (f": {_clip(body)}" if body else "")
        )
    return lines


def _due_today(db: sqlite3.Connection, day: date) -> list[str]:
    rows = db.execute(
        "SELECT text FROM todos WHERE deleted_at IS NULL AND done_at IS NULL "
        "AND substr(due_date, 1, 10) = ? ORDER BY created_at ASC LIMIT ?",
        (day.isoformat(), MAX_LIST_ITEMS),
    ).fetchall()
    return [f"- {_clip(row['text'] or '', 200)}" for row in rows if row["text"]]


_PIN_SOURCES = {
    "dump": ("dumps", "title", "recording"),
    "notebook": ("notebooks", "title", "notebook"),
    "todo": ("todos", "text", "to-do"),
}


def _pinned(db: sqlite3.Connection) -> list[str]:
    """Pinned items. The server keeps no pin column: pins travel only in
    device-pushed change_log payloads, and server-authored republishes omit
    the key (devices read absent as "unchanged"). So the pin state is the
    LATEST upsert payload that actually carries ``pinned`` — the same rule
    the client's pull applies."""
    rows = db.execute(
        """
        SELECT c.entity_type, c.entity_id, c.payload FROM change_log c
        WHERE c.entity_type IN ('dump', 'notebook', 'todo') AND c.op = 'upsert'
          AND json_valid(c.payload) AND json_type(c.payload, '$.pinned') IS NOT NULL
          AND c.seq = (
            SELECT MAX(c2.seq) FROM change_log c2
            WHERE c2.entity_type = c.entity_type AND c2.entity_id = c.entity_id
              AND c2.op = 'upsert' AND json_valid(c2.payload)
              AND json_type(c2.payload, '$.pinned') IS NOT NULL
          )
        ORDER BY c.entity_type, c.entity_id
        """
    ).fetchall()
    items: list[tuple[str, str]] = []
    for row in rows:
        try:
            pinned = json.loads(row["payload"]).get("pinned") is True
        except (TypeError, ValueError):
            continue
        if not pinned:
            continue
        table, column, label = _PIN_SOURCES[row["entity_type"]]
        live = db.execute(
            f"SELECT {column} FROM {table} WHERE id = ? AND deleted_at IS NULL",  # noqa: S608 - fixed identifiers
            (row["entity_id"],),
        ).fetchone()
        if live is None:
            continue
        title = (live[0] or "").strip() or "Untitled"
        items.append((title.lower(), f"- {_clip(title, 120)} ({label})"))
    return [line for _, line in sorted(items)][:MAX_LIST_ITEMS]


def build_input(db: sqlite3.Connection, day: date) -> str:
    """The aggregate the model reads; '' when the day has nothing at all."""
    sections = (
        ("## Captured yesterday", _captures(db, day)),
        ("## Due today", _due_today(db, day)),
        ("## Pinned", _pinned(db)),
    )
    parts = [head + "\n" + "\n".join(lines) for head, lines in sections if lines]
    return "\n".join(parts)


# --- output -------------------------------------------------------------------

_NONE_LINE = re.compile(r"^\s*(?:[-*]\s*)?None\b.*$", re.IGNORECASE)
_HIGHLIGHTS = re.compile(r"^\s*(?:\*\*Highlights\*\*|#+\s*Highlights)\s*:?\s*$", re.IGNORECASE)
_BULLET = re.compile(r"^\s*[-*]\s+\S")


def postprocess_brief(text: str) -> str:
    """Strip the model's placeholder residue: '- None' lines, an echoed
    'Output:' label, and a Highlights heading left with no bullets."""
    lines = [ln.rstrip() for ln in text.strip().splitlines()]
    if lines and lines[0].strip().lower() in ("output:", "output"):
        lines = lines[1:]
    lines = [ln for ln in lines if not _NONE_LINE.match(ln)]
    kept: list[str] = []
    for i, line in enumerate(lines):
        if _HIGHLIGHTS.match(line):
            rest = lines[i + 1 :]
            nxt = next((ln for ln in rest if ln.strip()), "")
            if not _BULLET.match(nxt):
                continue
        kept.append(line)
    out = "\n".join(kept)
    return re.sub(r"\n{3,}", "\n\n", out).strip()


# --- persistence --------------------------------------------------------------


def available(db: sqlite3.Connection) -> str | None:
    """None when the brief may exist; otherwise the 409 reason key."""
    if summarizer_env.python_path() is None:
        return "not_installed"
    if not summarizer_worker.summaries_enabled(db):
        return "disabled"
    return None


def get_brief(db: sqlite3.Connection, day: date) -> sqlite3.Row | None:
    return db.execute(
        "SELECT date, brief_md, model, generated_at FROM morning_briefs WHERE date = ?",
        (day.isoformat(),),
    ).fetchone()


def generate(
    db: sqlite3.Connection,
    day: date,
    *,
    force: bool = False,
    infer: Infer | None = None,
    now: int | None = None,
) -> bool:
    """Generate and cache ``day``'s brief. Idempotent per date: an existing
    brief is kept unless ``force``. Returns True when a brief is stored."""
    if available(db) is not None:
        return False
    if not force and get_brief(db, day) is not None:
        return True
    aggregate = build_input(db, day)
    if not aggregate:
        brief, model = EMPTY_DAY_BRIEF, EMPTY_DAY_MODEL
    else:
        run = infer or summarizer_worker.run_inference
        try:
            brief = postprocess_brief(
                run(f"morning-brief:{day.isoformat()}", aggregate, morning_brief_prompt())
            )
        except Exception as exc:  # never fatal: the brief is additive
            log.warning("morning_brief.generate_failed", date=day.isoformat(), error=str(exc))
            return False
        if not brief:
            log.warning("morning_brief.empty_output", date=day.isoformat())
            return False
        model = summarizer_worker.MODEL_STEM
    db.execute(
        "INSERT OR REPLACE INTO morning_briefs (date, brief_md, model, generated_at) "
        "VALUES (?, ?, ?, ?)",
        (day.isoformat(), brief, model, now if now is not None else int(time.time())),
    )
    db.commit()
    log.info("morning_brief.generated", date=day.isoformat(), model=model)
    return True


# --- scheduler ----------------------------------------------------------------

_lock = threading.Lock()  # one generation at a time (scheduler or explicit)
_stop = threading.Event()
_thread: threading.Thread | None = None
_attempts: dict[str, tuple[int, float]] = {}  # date -> (count, last monotonic)


def _due(now_local: datetime) -> bool:
    return now_local.hour * 60 + now_local.minute >= GENERATE_AT_MINUTE


def tick(
    db: sqlite3.Connection,
    now_local: datetime | None = None,
    *,
    infer: Infer | None = None,
    monotonic: Callable[[], float] = time.monotonic,
) -> bool:
    """One scheduler step: generate today's brief if it is due, gated, not
    cached, and not inside a failure back-off. Never raises."""
    try:
        now_local = now_local or datetime.now().astimezone()
        if not _due(now_local) or available(db) is not None:
            return False
        day = now_local.date()
        if get_brief(db, day) is not None:
            return False
        key = day.isoformat()
        count, last = _attempts.get(key, (0, float("-inf")))
        if count >= MAX_ATTEMPTS_PER_DAY or monotonic() - last < RETRY_AFTER_S:
            return False
        with _lock:
            ok = generate(db, day, infer=infer)
        if not ok:
            _attempts[key] = (count + 1, monotonic())
        return ok
    except Exception:
        log.exception("morning_brief.tick_failed")
        return False


def generate_now(day: date) -> None:
    """Explicit regenerate (background thread body). Never raises."""
    from app.db import get_db

    gen = get_db()
    db = next(gen)
    try:
        with _lock:
            generate(db, day, force=True)
    except Exception:
        log.exception("morning_brief.regenerate_failed", date=day.isoformat())
    finally:
        with contextlib.suppress(StopIteration):
            next(gen)


def _loop() -> None:
    from app.db import get_db

    while not _stop.is_set():
        gen = get_db()
        try:
            db = next(gen)
            tick(db)
        except Exception:
            log.exception("morning_brief.loop_failed")
        finally:
            with contextlib.suppress(Exception):
                next(gen)
        _stop.wait(TICK_S)


def start_scheduler() -> threading.Thread:
    global _thread
    if _thread is not None and _thread.is_alive():
        return _thread
    _stop.clear()
    _thread = threading.Thread(target=_loop, name="morning-brief", daemon=True)
    _thread.start()
    return _thread


def stop_scheduler() -> None:
    global _thread
    _stop.set()
    if _thread is not None:
        _thread.join(timeout=5)
    _thread = None


def _reset_for_tests() -> None:
    stop_scheduler()
    _attempts.clear()
