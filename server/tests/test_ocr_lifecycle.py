# SPDX-License-Identifier: AGPL-3.0-or-later
"""Worker lifecycle across install/uninstall (Task 3 fix round 1).

The wizard flow (Task 5) is: toggle → install → indexing starts, with NO
container restart. That pins two behaviors:

1. An install that completes on a LIVE server must start the worker (and its
   backfill scan must drain pre-existing notebooks) — not wait for a restart.
2. Uninstall must stop the worker and clear the pending queue BEFORE deleting
   the venv, or queued notebooks get processed against a dead env and
   repopulate the just-wiped ink_index with all-error junk rows.

No real installs: the step runner is always injected.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.db import init_db
from app.main import create_app
from app.services import ocr_env, ocr_worker


@pytest.fixture(autouse=True)
def _reset_lifecycle_state():
    """Both modules keep module-level state; isolate every test."""
    ocr_worker._reset_for_tests()
    ocr_env._reset_state_for_tests()
    yield
    ocr_worker._reset_for_tests()
    ocr_env._reset_state_for_tests()


def fake_runner(step: ocr_env.InstallStep) -> None:
    """Execute no real steps; emulate venv creation so python_path() works."""
    if step.kind == "venv":
        dest = Path(step.dest)
        for cand in (dest / "Scripts" / "python.exe", dest / "bin" / "python"):
            cand.parent.mkdir(parents=True, exist_ok=True)
            cand.write_text("")


def _wait_for(cond, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while not cond() and time.time() < deadline:
        time.sleep(0.01)
    return cond()


def _open_db(data_dir: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _insert_inked_notebook(data_dir: Path, nb_id: str) -> None:
    conn = _open_db(data_dir)
    try:
        conn.execute(
            "INSERT INTO notebooks (id, title, doc, ink, created_at, updated_at) "
            "VALUES (?, 'T', '{}', ?, 1, 1)",
            (nb_id, json.dumps({"strokes": []})),
        )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Finding 1: live install completion starts the worker (no restart)
# ---------------------------------------------------------------------------


def test_live_install_completion_starts_worker_and_drains_backfill(
    temp_data_dir, monkeypatch
):
    """POST /v1/ocr/install on a running server → worker starts + backfill
    drains, all without an app restart. The full wizard flow."""
    monkeypatch.setattr(ocr_env, "default_runner", fake_runner)
    monkeypatch.setattr(ocr_env, "probe_gpu_visible", lambda: False)

    processed: list[str] = []
    monkeypatch.setattr(
        ocr_worker,
        "reindex_notebook",
        lambda db, notebook_id, *a, **k: processed.append(notebook_id),
    )

    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        auth = {"Authorization": f"Bearer {token}"}

        # A notebook that synced while OCR was uninstalled: the backfill
        # scan (not a sync push) must find it when the worker starts.
        _insert_inked_notebook(temp_data_dir, "nb-backlog")
        assert not ocr_worker.worker_running()

        resp = cli.post("/v1/ocr/install", json={"flavour": "cpu"}, headers=auth)
        assert resp.status_code == 202
        assert _wait_for(lambda: not ocr_env.install_running())
        assert ocr_env.progress()["phase"] == "done"

        assert _wait_for(ocr_worker.worker_running), (
            "a completed live install must start the worker without a restart"
        )
        assert _wait_for(lambda: processed == ["nb-backlog"]), (
            "the started worker must run its backfill scan and drain it"
        )

        status = cli.get("/v1/ocr/status", headers=auth).json()
        assert status["installed"] is True
        assert status["worker_running"] is True


def test_install_success_fires_on_installed_hook_after_publish(temp_data_dir):
    """The hook fires exactly once, only after the env dir is published."""
    seen: list[bool] = []
    ocr_env.set_on_installed(lambda: seen.append(ocr_env.env_dir().is_dir()))

    ocr_env.install("cpu", runner=fake_runner)

    assert seen == [True], "hook must fire once, AFTER the atomic publish"


def test_failed_install_does_not_fire_on_installed_hook(temp_data_dir):
    calls: list[int] = []
    ocr_env.set_on_installed(lambda: calls.append(1))

    def exploding_runner(step: ocr_env.InstallStep) -> None:
        if step.phase == "torch":
            raise RuntimeError("boom during torch")
        fake_runner(step)

    with pytest.raises(ocr_env.InstallError):
        ocr_env.install("cpu", runner=exploding_runner)

    assert calls == [], "a failed install must not start the worker"


def test_hook_exception_does_not_fail_a_successful_install(temp_data_dir):
    """The env IS installed once published; a broken hook must not lie about
    that by raising InstallError or rolling progress back to 'failed'."""

    def bad_hook() -> None:
        raise RuntimeError("hook exploded")

    ocr_env.set_on_installed(bad_hook)
    ocr_env.install("cpu", runner=fake_runner)  # must NOT raise

    assert ocr_env.progress()["phase"] == "done"
    assert ocr_env.python_path() is not None


# ---------------------------------------------------------------------------
# Finding 2: uninstall stops the worker + clears the queue BEFORE the wipe
# ---------------------------------------------------------------------------


class _RecordingDb:
    """Passthrough sqlite wrapper that timestamps uninstall's destructive
    statements into a shared event log (uninstall only uses execute/commit)."""

    def __init__(self, conn, log: list[tuple[str, dict]]):
        self._conn = conn
        self._log = log

    def execute(self, sql, *args):
        if "DELETE FROM ink_index" in sql:
            self._log.append(("delete_ink_index", _snapshot()))
        return self._conn.execute(sql, *args)

    def commit(self):
        self._log.append(("commit", _snapshot()))
        return self._conn.commit()


def _snapshot() -> dict:
    """State visible to a notebook that the worker might still pick up."""
    return {
        "worker_running": ocr_worker.worker_running(),
        "pending": ocr_worker.pending(),
        "env_exists": ocr_env.env_dir().exists(),
    }


def test_uninstall_stops_running_worker_and_clears_queue(
    temp_data_dir, monkeypatch
):
    """Worker busy on one notebook, another queued behind it: uninstall must
    stop the worker and drop the queued one — it must NEVER be processed
    (against a deleted env it would only produce all-error junk rows).

    This pins the ORDER directly, not just the end state: every destructive
    step (rmtree of the env, DELETE FROM ink_index, commit) is observed live
    and must find the worker already stopped and the queue already empty.
    A refactor that wipes first and stops after leaves an identical end state
    but fails here.
    """
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=fake_runner)

    processed: list[str] = []

    def blocking_reindex(db, notebook_id, *a, **k):
        processed.append(notebook_id)
        ocr_worker._stop.wait(timeout=10)  # busy until asked to stop

    monkeypatch.setattr(ocr_worker, "reindex_notebook", blocking_reindex)

    events: list[tuple[str, dict]] = []

    real_stop, real_clear = ocr_worker.stop_worker, ocr_worker.clear_queue
    real_rmtree = ocr_env.shutil.rmtree

    def recording_stop():
        real_stop()
        events.append(("stop_worker", _snapshot()))

    def recording_clear():
        real_clear()
        events.append(("clear_queue", _snapshot()))

    def recording_rmtree(path, *a, **k):
        events.append((f"rmtree:{Path(path).name}", _snapshot()))
        return real_rmtree(path, *a, **k)

    monkeypatch.setattr(ocr_worker, "stop_worker", recording_stop)
    monkeypatch.setattr(ocr_worker, "clear_queue", recording_clear)
    monkeypatch.setattr(ocr_env.shutil, "rmtree", recording_rmtree)

    assert ocr_worker.start_worker_if_installed() is not None
    ocr_worker.enqueue("nb-busy")
    assert _wait_for(lambda: processed == ["nb-busy"]), "worker never got busy"
    ocr_worker.enqueue("nb-queued")
    assert ocr_worker.pending() == ["nb-queued"]

    conn = _open_db(temp_data_dir)
    try:
        assert ocr_env.uninstall(_RecordingDb(conn, events)) is True
    finally:
        conn.close()

    # --- end state ---------------------------------------------------------
    assert not ocr_worker.worker_running(), "uninstall must stop the worker"
    assert ocr_worker.pending() == [], "uninstall must clear the pending queue"
    assert processed == ["nb-busy"], (
        "the queued notebook must never be processed after uninstall"
    )
    assert not ocr_env.env_dir().exists()

    # --- ORDER: quiesce BEFORE destroy ------------------------------------
    names = [name for name, _ in events]
    assert names[:2] == ["stop_worker", "clear_queue"], (
        "uninstall must stop the worker and clear the queue FIRST, before it "
        f"touches the env or ink_index; actual order was {names}"
    )
    destructive = [(name, snap) for name, snap in events if name not in
                   ("stop_worker", "clear_queue")]
    assert [name for name, _ in destructive] == [
        f"rmtree:{ocr_env.env_dir().name}",
        "delete_ink_index",
        "commit",
    ], f"unexpected destructive sequence: {[n for n, _ in destructive]}"

    # The queue was drained while the env was still on disk: that is exactly
    # the window in which a surviving worker would write model='error' junk.
    quiesce = dict(events[:2])
    assert quiesce["stop_worker"]["env_exists"] is True, (
        "the worker must be stopped while the env still exists (it was stopped "
        "only after the wipe — the junk-row race is open again)"
    )
    assert quiesce["clear_queue"]["env_exists"] is True
    assert quiesce["clear_queue"]["pending"] == []

    for name, snap in destructive:
        assert snap["worker_running"] is False, (
            f"worker was still running at {name}: it can process a queued "
            "notebook against a half-deleted env and repopulate ink_index"
        )
        assert snap["pending"] == [], (
            f"queue was still non-empty at {name}: {snap['pending']} would be "
            "processed against a half-deleted env"
        )


def test_uninstall_clears_queue_even_when_worker_never_ran(temp_data_dir):
    """The queue accepts entries while uninstalled; uninstall must drop them
    so a later re-install's backfill starts from truth, not stale wishes."""
    init_db(str(temp_data_dir))
    ocr_worker.enqueue("nb-stale")
    assert ocr_worker.pending() == ["nb-stale"]

    conn = _open_db(temp_data_dir)
    try:
        assert ocr_env.uninstall(conn) is True
    finally:
        conn.close()

    assert ocr_worker.pending() == []


# ---------------------------------------------------------------------------
# Final review: uninstall must PUBLISH the index deletion, not just perform it
# ---------------------------------------------------------------------------
#
# `DELETE FROM ink_index` alone cleans only the server. Clients mirror the
# index via change_log (one ink_index change per notebook; the payload is a
# replace-set built at pull time — a delete simply replace-sets to empty), so
# without a recorded delete per notebook no device EVER pulls the removal and
# every client's handwriting-search mirror stays stale forever, breaking the
# wizard's promise that uninstall deletes the handwriting search index.


def _seed_ink_rows(conn: sqlite3.Connection, notebook_ids: list[str]) -> None:
    for nb in notebook_ids:
        conn.execute(
            "INSERT INTO ink_index "
            "(id, notebook_id, line_id, word_text, word_text_lower, "
            " bbox_json, stroke_ids_json, model, indexed_at) "
            "VALUES (?, ?, 'line-1', 'hello', 'hello', '[0,0,1,1]', "
            "'[\"s-a\"]', 'trocr-base', 1)",
            (f"{nb}:000", nb),
        )
    conn.commit()


def test_uninstall_publishes_an_ink_index_delete_per_indexed_notebook(
    temp_data_dir,
):
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=fake_runner)

    conn = _open_db(temp_data_dir)
    try:
        _seed_ink_rows(conn, ["nb-1", "nb-2"])

        assert ocr_env.uninstall(conn) is True

        rows = conn.execute(
            "SELECT entity_id, op, payload FROM change_log "
            "WHERE entity_type = 'ink_index' ORDER BY entity_id"
        ).fetchall()
        assert [(r["entity_id"], r["op"]) for r in rows] == [
            ("nb-1", "delete"),
            ("nb-2", "delete"),
        ], "one ink_index delete per indexed notebook, or clients never learn"
        assert all(r["payload"] is None for r in rows), (
            "a delete is a tombstone; it must carry no payload"
        )
        n = conn.execute("SELECT COUNT(*) AS n FROM ink_index").fetchone()["n"]
        assert n == 0
    finally:
        conn.close()


class _CommitObservingDb:
    """Passthrough that snapshots what a SECOND connection can see at the
    instant uninstall commits. Before that commit is delegated, an outside
    observer must see NONE of the mutation (rows intact, no delete changes) —
    proving DELETE + record_change travel in one transaction and a crash
    between them loses both, never just one."""

    def __init__(self, conn: sqlite3.Connection, data_dir: Path):
        self._conn = conn
        self._data_dir = data_dir
        self.seen_before_commit: dict | None = None

    def execute(self, sql, *args):
        return self._conn.execute(sql, *args)

    def commit(self):
        other = _open_db(self._data_dir)
        try:
            self.seen_before_commit = {
                "ink_rows": other.execute(
                    "SELECT COUNT(*) AS n FROM ink_index"
                ).fetchone()["n"],
                "delete_changes": other.execute(
                    "SELECT COUNT(*) AS n FROM change_log "
                    "WHERE entity_type = 'ink_index' AND op = 'delete'"
                ).fetchone()["n"],
            }
        finally:
            other.close()
        return self._conn.commit()


def test_uninstall_delete_and_change_entries_commit_atomically(temp_data_dir):
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=fake_runner)

    conn = _open_db(temp_data_dir)
    try:
        _seed_ink_rows(conn, ["nb-1", "nb-2"])
        db = _CommitObservingDb(conn, temp_data_dir)

        assert ocr_env.uninstall(db) is True

        assert db.seen_before_commit == {"ink_rows": 2, "delete_changes": 0}, (
            "an outside connection saw a partial state before commit: the "
            "DELETE and its change_log entries must be in ONE transaction "
            f"(saw {db.seen_before_commit})"
        )
        # After the single commit, ALL of it is visible.
        after = _open_db(temp_data_dir)
        try:
            assert after.execute(
                "SELECT COUNT(*) AS n FROM ink_index"
            ).fetchone()["n"] == 0
            assert after.execute(
                "SELECT COUNT(*) AS n FROM change_log "
                "WHERE entity_type = 'ink_index' AND op = 'delete'"
            ).fetchone()["n"] == 2
        finally:
            after.close()
    finally:
        conn.close()


def test_client_pull_after_uninstall_delivers_the_deletions(temp_data_dir):
    """The full fleet-cleanup path: uninstall via the API, then a device's
    next pull carries an ink_index delete per notebook — the signal that
    replace-sets its local mirror to empty."""
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        auth = {"Authorization": f"Bearer {token}"}

        _insert_inked_notebook(temp_data_dir, "nb-ink")
        conn = _open_db(temp_data_dir)
        try:
            _seed_ink_rows(conn, ["nb-ink"])
        finally:
            conn.close()

        assert cli.post("/v1/ocr/uninstall", headers=auth).status_code == 200

        pulled = cli.get(
            "/v1/sync/pull",
            params={
                "device_id": "device-bbbb-2",
                "since_seq": 0,
                "include_ink_index": True,
            },
            headers=auth,
        ).json()
        deletes = [
            c["entity_id"]
            for c in pulled["changes"]
            if c["entity_type"] == "ink_index" and c["op"] == "delete"
        ]
        assert deletes == ["nb-ink"], (
            "a client's next pull after uninstall must carry the deletion, "
            f"or its mirror is stale forever; pulled {pulled['changes']}"
        )
