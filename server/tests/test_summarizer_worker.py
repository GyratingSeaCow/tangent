# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the AI-summaries worker (Task 2).

Inference is always injected (``infer=lambda dump_id, transcript: "..."``) —
no test loads llama-cpp or a real model. ``run_inference``'s subprocess
plumbing is exercised against a stub script run by the test interpreter,
exactly like the ocr_worker tests.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

from app.db import init_db
from app.services import summarizer_worker
from app.summarize_infer import MODEL_FILENAME


@pytest.fixture(autouse=True)
def _reset_worker():
    """summarizer_worker keeps a module-level queue + thread; isolate tests."""
    summarizer_worker._reset_for_tests()
    yield
    summarizer_worker._reset_for_tests()


@pytest.fixture
def db(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def _insert_dump(
    db: sqlite3.Connection,
    dump_id: str,
    transcript: str | None = "Sam: let's ship it.\nLee: agreed.",
    mode: str = "meeting",
    deleted: bool = False,
) -> None:
    db.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, audio_kept, deleted_at) "
        "VALUES (?, 'single-user', 1, 1, ?, 60, 'T', ?, 0, ?)",
        (dump_id, mode, transcript, 1 if deleted else None),
    )
    db.commit()


def _dump_row(db: sqlite3.Connection, dump_id: str) -> sqlite3.Row:
    return db.execute(
        "SELECT summary, summary_model, summarized_at FROM dumps WHERE id = ?",
        (dump_id,),
    ).fetchone()


def _dump_changes(db: sqlite3.Connection, dump_id: str) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT * FROM change_log WHERE entity_type = 'dump' AND entity_id = ? "
        "ORDER BY seq",
        (dump_id,),
    ).fetchall()


class _WarningLog:
    """Records log.warning events; every other level is a no-op."""

    def __init__(self) -> None:
        self.warnings: list[tuple[str, dict]] = []

    def __getattr__(self, name):
        def _record(event, **kw):
            if name == "warning":
                self.warnings.append((event, kw))

        return _record


# ---------------------------------------------------------------------------
# summarize_dump: the unit
# ---------------------------------------------------------------------------


SUMMARY_MD = "## Summary\nShipped it.\n\n## Key decisions\n- Ship."


class TestSummarizeDump:
    def test_success_writes_all_three_columns_and_a_change_log_entry(self, db):
        _insert_dump(db, "d-1")

        ok = summarizer_worker.summarize_dump(
            db, "d-1", infer=lambda i, t: SUMMARY_MD, now=1234
        )

        assert ok is True
        row = _dump_row(db, "d-1")
        assert row["summary"] == SUMMARY_MD
        assert row["summary_model"] == Path(MODEL_FILENAME).stem, (
            "summary_model must be the exact GGUF stem"
        )
        assert row["summarized_at"] == 1234
        changes = _dump_changes(db, "d-1")
        assert changes, "the summary write must be announced to sync"
        payload = json.loads(changes[-1]["payload"])
        assert payload["summary"] == SUMMARY_MD
        assert changes[-1]["op"] == "upsert"
        assert changes[-1]["device_id"] == "server"

    def test_success_survives_a_second_connection_read(self, db, temp_data_dir):
        """The write is committed, not just staged on this connection."""
        _insert_dump(db, "d-commit")
        summarizer_worker.summarize_dump(
            db, "d-commit", infer=lambda i, t: SUMMARY_MD, now=1
        )
        other = sqlite3.connect(temp_data_dir / "tangent.db")
        other.row_factory = sqlite3.Row
        try:
            row = other.execute(
                "SELECT summary FROM dumps WHERE id = 'd-commit'"
            ).fetchone()
        finally:
            other.close()
        assert row["summary"] == SUMMARY_MD

    def test_regenerate_replaces_the_previous_summary(self, db):
        _insert_dump(db, "d-re")
        summarizer_worker.summarize_dump(
            db, "d-re", infer=lambda i, t: "old", now=1
        )
        summarizer_worker.summarize_dump(
            db, "d-re", infer=lambda i, t: "new", now=2
        )
        row = _dump_row(db, "d-re")
        assert row["summary"] == "new", "idempotent replace"
        assert row["summarized_at"] == 2

    def test_infer_failure_logs_warning_and_leaves_summary_null(
        self, db, monkeypatch
    ):
        fake_log = _WarningLog()
        monkeypatch.setattr(summarizer_worker, "log", fake_log)
        _insert_dump(db, "d-fail")

        def exploding(i, t):
            raise RuntimeError("model exploded")

        ok = summarizer_worker.summarize_dump(db, "d-fail", infer=exploding)

        assert ok is False
        assert _dump_row(db, "d-fail")["summary"] is None
        assert _dump_changes(db, "d-fail") == [], (
            "a failed summarize must not announce anything"
        )
        events = [e for e, _ in fake_log.warnings]
        assert "summarizer_worker.summarize_failed" in events

    def test_missing_dump_is_a_noop(self, db):
        ok = summarizer_worker.summarize_dump(
            db, "d-ghost", infer=lambda i, t: SUMMARY_MD
        )
        assert ok is False

    def test_deleted_dump_is_not_summarized(self, db):
        _insert_dump(db, "d-dead", deleted=True)
        ok = summarizer_worker.summarize_dump(
            db, "d-dead", infer=lambda i, t: SUMMARY_MD
        )
        assert ok is False
        assert _dump_row(db, "d-dead")["summary"] is None

    def test_empty_transcript_logs_warning_and_skips(self, db, monkeypatch):
        fake_log = _WarningLog()
        monkeypatch.setattr(summarizer_worker, "log", fake_log)
        _insert_dump(db, "d-mute", transcript="   ")
        calls: list = []
        ok = summarizer_worker.summarize_dump(
            db, "d-mute", infer=lambda i, t: calls.append(t) or "x"
        )
        assert ok is False
        assert calls == [], "no transcript, no inference"
        assert any(
            e == "summarizer_worker.no_transcript" for e, _ in fake_log.warnings
        )

    def test_empty_summary_is_a_failure_not_a_write(self, db):
        _insert_dump(db, "d-empty")
        ok = summarizer_worker.summarize_dump(db, "d-empty", infer=lambda i, t: "")
        assert ok is False
        assert _dump_row(db, "d-empty")["summary"] is None

    def test_column_write_and_change_log_share_one_transaction(
        self, db, temp_data_dir, monkeypatch
    ):
        """If the feed announce fails, the column write must roll back —
        otherwise a summary exists that no device is ever told about."""
        _insert_dump(db, "d-atomic")

        def exploding_publish(*a, **kw):
            raise sqlite3.OperationalError("change_log write failed")

        monkeypatch.setattr(
            "app.api.dumps._publish_dump_change", exploding_publish
        )
        ok = summarizer_worker.summarize_dump(
            db, "d-atomic", infer=lambda i, t: SUMMARY_MD
        )

        assert ok is False
        other = sqlite3.connect(temp_data_dir / "tangent.db")
        other.row_factory = sqlite3.Row
        try:
            row = other.execute(
                "SELECT summary FROM dumps WHERE id = 'd-atomic'"
            ).fetchone()
        finally:
            other.close()
        assert row["summary"] is None, (
            "summary column write must commit WITH the change_log entry or not at all"
        )


# ---------------------------------------------------------------------------
# run_inference: the persistent-child subprocess boundary
# ---------------------------------------------------------------------------
#
# The seam: a stub script stands in for ``summarize_infer.py --serve`` and
# the test interpreter stands in for the venv python. Each stub appends its
# PID to a spawn log on startup — child-process count is asserted from that
# file, so a regression back to one-subprocess-per-request is caught by
# count, not by implementation detail.

_SERVE_PREAMBLE = (
    "import json, os, sys\n"
    "assert '--serve' in sys.argv, 'worker must start the child in serve mode'\n"
    "log = os.environ['SUM_STUB_SPAWN_LOG']\n"
    "with open(log, 'a') as f:\n"
    "    f.write(str(os.getpid()) + '\\n')\n"
    "spawn_n = sum(1 for _ in open(log))\n"
)

#: Healthy child: echoes each request id back with a stub summary, forever.
_SERVE_FOREVER = (
    "for line in sys.stdin:\n"
    "    req = json.loads(line)\n"
    "    assert req['transcript'], 'transcript must reach the child'\n"
    "    print(json.dumps({'id': req['id'], 'summary': '  stub summary  '}), flush=True)\n"
)

#: First spawn: serves ONE request then dies mid-batch. Later spawns: healthy.
_SERVE_ONE_THEN_CRASH = (
    "served = 0\n"
    "for line in sys.stdin:\n"
    "    req = json.loads(line)\n"
    "    print(json.dumps({'id': req['id'], 'summary': 'crashy summary'}), flush=True)\n"
    "    served += 1\n"
    "    if spawn_n == 1 and served == 1:\n"
    "        os._exit(1)\n"
)

#: Reads requests and never answers them.
_SERVE_HANG = (
    "import time\n"
    "for line in sys.stdin:\n"
    "    time.sleep(60)\n"
)

#: Healthy child that reports a per-request error (stays up).
_SERVE_ERROR = (
    "for line in sys.stdin:\n"
    "    req = json.loads(line)\n"
    "    print(json.dumps({'id': req['id'], 'error': 'ctx overflow'}), flush=True)\n"
)


def _install_serve_stub(monkeypatch, tmp_path: Path, behavior: str) -> Path:
    """Point the worker at a stub serve child; return the spawn-log path."""
    stub = tmp_path / "serve_stub.py"
    stub.write_text(_SERVE_PREAMBLE + behavior, encoding="utf-8")
    spawn_log = tmp_path / "spawns.log"
    spawn_log.write_text("", encoding="utf-8")
    monkeypatch.setenv("SUM_STUB_SPAWN_LOG", str(spawn_log))
    monkeypatch.setattr(
        summarizer_worker.summarizer_env, "python_path", lambda: sys.executable
    )
    monkeypatch.setattr(summarizer_worker, "_infer_script", lambda: stub)
    return spawn_log


def _spawns(spawn_log: Path) -> int:
    return len(spawn_log.read_text(encoding="utf-8").splitlines())


def test_run_inference_raises_when_env_not_installed(temp_data_dir):
    with pytest.raises(RuntimeError, match="not installed"):
        summarizer_worker.run_inference("d-1", "Sam: hi")


def test_run_inference_speaks_the_serve_protocol(monkeypatch, tmp_path):
    # Pinned contract: the child is started with --serve, receives one JSON
    # object per line, and the summary comes back stripped.
    _install_serve_stub(monkeypatch, tmp_path, _SERVE_FOREVER)

    out = summarizer_worker.run_inference("d-1", "Sam: hello")
    assert out == "stub summary"


def test_model_loads_once_two_requests_share_one_child(monkeypatch, tmp_path):
    # THE point of the persistent child: N summaries, ONE spawn (one model
    # load). A regression to subprocess-per-request shows up as spawn count 2.
    spawn_log = _install_serve_stub(monkeypatch, tmp_path, _SERVE_FOREVER)

    assert summarizer_worker.run_inference("d-1", "Sam: a") == "stub summary"
    assert summarizer_worker.run_inference("d-2", "Lee: b") == "stub summary"
    assert _spawns(spawn_log) == 1, "two requests must reuse one serve child"


def test_child_crash_restarts_once_and_second_request_succeeds(
    monkeypatch, tmp_path
):
    spawn_log = _install_serve_stub(monkeypatch, tmp_path, _SERVE_ONE_THEN_CRASH)
    fake_log = _WarningLog()
    monkeypatch.setattr(summarizer_worker, "log", fake_log)

    # First request answered, then the child dies; second request must pay
    # exactly one restart and still succeed.
    assert summarizer_worker.run_inference("d-1", "t") == "crashy summary"
    assert summarizer_worker.run_inference("d-2", "t") == "crashy summary"

    assert _spawns(spawn_log) == 2, "exactly one restart"
    restarts = [
        e for e, _ in fake_log.warnings if e == "summarizer_worker.infer_restarted"
    ]
    assert len(restarts) == 1, "the restart must be logged as a WARNING"


def test_per_request_deadline_kills_and_restarts_then_surfaces(
    db, monkeypatch, tmp_path
):
    spawn_log = _install_serve_stub(monkeypatch, tmp_path, _SERVE_HANG)
    monkeypatch.setattr(summarizer_worker, "INFER_TIMEOUT_S", 0.5)
    fake_log = _WarningLog()
    monkeypatch.setattr(summarizer_worker, "log", fake_log)

    _insert_dump(db, "d-slow")
    ok = summarizer_worker.summarize_dump(
        db, "d-slow", infer=summarizer_worker.run_inference
    )

    assert ok is False
    assert _dump_row(db, "d-slow")["summary"] is None, (
        "a hung child leaves summary NULL"
    )
    assert _spawns(spawn_log) == 2, "the hung child is killed and restarted once"
    events = [e for e, _ in fake_log.warnings]
    assert "summarizer_worker.infer_restarted" in events
    assert "summarizer_worker.summarize_failed" in events
    assert summarizer_worker._infer_child is None, "both hung children discarded"


def test_child_reported_error_is_no_restart(db, monkeypatch, tmp_path):
    # A healthy child rejecting one request must NOT cost a restart — the
    # model stays loaded for the next dump.
    spawn_log = _install_serve_stub(monkeypatch, tmp_path, _SERVE_ERROR)
    fake_log = _WarningLog()
    monkeypatch.setattr(summarizer_worker, "log", fake_log)

    _insert_dump(db, "d-err")
    ok = summarizer_worker.summarize_dump(
        db, "d-err", infer=summarizer_worker.run_inference
    )

    assert ok is False
    assert _dump_row(db, "d-err")["summary"] is None
    assert _spawns(spawn_log) == 1, "per-request errors keep the child alive"
    assert any(
        e == "summarizer_worker.summarize_failed" and "ctx overflow" in str(kw)
        for e, kw in fake_log.warnings
    )


def test_run_inference_surfaces_child_death_after_one_restart(
    monkeypatch, tmp_path
):
    # A child that dies at startup: restart once, then surface the failure —
    # never an infinite respawn loop.
    spawn_log = _install_serve_stub(monkeypatch, tmp_path, "sys.exit(3)\n")

    with pytest.raises(RuntimeError, match="exited 3"):
        summarizer_worker.run_inference("d-1", "t")
    assert _spawns(spawn_log) == 2, "one restart attempt, then give up"


def test_stop_worker_kills_the_persistent_child(monkeypatch, tmp_path):
    # uninstall's quiesce-first contract: stop_worker runs BEFORE the env
    # wipe and must leave no live child behind (no orphan holding the venv).
    _install_serve_stub(monkeypatch, tmp_path, _SERVE_FOREVER)

    summarizer_worker.run_inference("d-1", "t")
    child = summarizer_worker._infer_child
    assert child is not None and child.proc.poll() is None, "child is live"

    summarizer_worker.stop_worker()

    assert child.proc.poll() is not None, "stop_worker must not orphan the child"
    assert summarizer_worker._infer_child is None


# ---------------------------------------------------------------------------
# queue + worker gating + toggle + auto-trigger
# ---------------------------------------------------------------------------


def test_enqueue_deduplicates_while_pending():
    summarizer_worker.enqueue("d-1")
    summarizer_worker.enqueue("d-2")
    summarizer_worker.enqueue("d-1")
    assert summarizer_worker.pending() == ["d-1", "d-2"]


def test_clear_queue_drops_everything():
    summarizer_worker.enqueue("d-1")
    summarizer_worker.clear_queue()
    assert summarizer_worker.pending() == []


def test_worker_does_not_start_without_an_installed_env(temp_data_dir):
    assert summarizer_worker.start_worker_if_installed() is None
    assert not summarizer_worker.worker_running()


def test_worker_starts_when_installed_and_drains_the_queue(
    temp_data_dir, monkeypatch
):
    init_db(str(temp_data_dir))
    monkeypatch.setattr(
        summarizer_worker.summarizer_env, "python_path", lambda: sys.executable
    )
    done: list[str] = []
    monkeypatch.setattr(
        summarizer_worker,
        "summarize_dump",
        lambda db, dump_id, *a, **kw: done.append(dump_id) or True,
    )

    summarizer_worker.enqueue("d-1")
    assert summarizer_worker.start_worker_if_installed() is not None
    deadline = time.time() + 10
    while done != ["d-1"] and time.time() < deadline:
        time.sleep(0.01)
    assert done == ["d-1"], "the worker thread must drain the queue"
    assert summarizer_worker.worker_running()


def test_toggle_defaults_off_and_persists(db):
    assert summarizer_worker.summaries_enabled(db) is False
    summarizer_worker.set_summaries_enabled(db, True)
    assert summarizer_worker.summaries_enabled(db) is True
    summarizer_worker.set_summaries_enabled(db, False)
    assert summarizer_worker.summaries_enabled(db) is False


class TestAutoTrigger:
    """Eligibility is exactly: mode=meeting AND installed AND enabled."""

    def _installed(self, monkeypatch, yes: bool = True):
        monkeypatch.setattr(
            summarizer_worker.summarizer_env,
            "python_path",
            (lambda: sys.executable) if yes else (lambda: None),
        )

    def test_meeting_installed_enabled_enqueues(self, db, monkeypatch):
        self._installed(monkeypatch)
        summarizer_worker.set_summaries_enabled(db, True)
        # Keep the worker thread from consuming the entry before we assert.
        monkeypatch.setattr(
            summarizer_worker, "start_worker_if_installed", lambda: None
        )
        assert summarizer_worker.maybe_enqueue_auto(db, "d-m", "meeting") is True
        assert summarizer_worker.pending() == ["d-m"]

    def test_non_meeting_mode_never_auto_triggers(self, db, monkeypatch):
        self._installed(monkeypatch)
        summarizer_worker.set_summaries_enabled(db, True)
        for mode in ("brain_dump", "text_note"):
            assert summarizer_worker.maybe_enqueue_auto(db, "d-x", mode) is False
        assert summarizer_worker.pending() == []

    def test_not_installed_never_auto_triggers(self, db, monkeypatch):
        self._installed(monkeypatch, yes=False)
        summarizer_worker.set_summaries_enabled(db, True)
        assert summarizer_worker.maybe_enqueue_auto(db, "d-m", "meeting") is False
        assert summarizer_worker.pending() == []

    def test_toggle_off_never_auto_triggers(self, db, monkeypatch):
        self._installed(monkeypatch)
        assert summarizer_worker.summaries_enabled(db) is False
        assert summarizer_worker.maybe_enqueue_auto(db, "d-m", "meeting") is False
        assert summarizer_worker.pending() == []
