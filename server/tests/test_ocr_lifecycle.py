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


def test_uninstall_stops_running_worker_and_clears_queue(
    temp_data_dir, monkeypatch
):
    """Worker busy on one notebook, another queued behind it: uninstall must
    stop the worker and drop the queued one — it must NEVER be processed
    (against a deleted env it would only produce all-error junk rows)."""
    init_db(str(temp_data_dir))
    ocr_env.install("cpu", runner=fake_runner)

    processed: list[str] = []

    def blocking_reindex(db, notebook_id, *a, **k):
        processed.append(notebook_id)
        ocr_worker._stop.wait(timeout=10)  # busy until asked to stop

    monkeypatch.setattr(ocr_worker, "reindex_notebook", blocking_reindex)

    assert ocr_worker.start_worker_if_installed() is not None
    ocr_worker.enqueue("nb-busy")
    assert _wait_for(lambda: processed == ["nb-busy"]), "worker never got busy"
    ocr_worker.enqueue("nb-queued")
    assert ocr_worker.pending() == ["nb-queued"]

    conn = _open_db(temp_data_dir)
    try:
        assert ocr_env.uninstall(conn) is True
    finally:
        conn.close()

    assert not ocr_worker.worker_running(), "uninstall must stop the worker"
    assert ocr_worker.pending() == [], "uninstall must clear the pending queue"
    assert processed == ["nb-busy"], (
        "the queued notebook must never be processed after uninstall"
    )
    assert not ocr_env.env_dir().exists()


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
