# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the OCR index worker (Task 3).

Inference is always injected (``infer=lambda img: "hello world"``) — no test
loads torch or a real model. ``run_inference``'s subprocess plumbing is
exercised against a stub script run by the test interpreter.

Geometry notes for the stroke helpers below: every stroke is 20px tall, so the
segmenter's median height H is 20. Words split at x-gaps > 0.6*H = 12px; lines
split at y-centre gaps > 0.9*H = 18px.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from app.auth import generate_token, hash_token
from app.db import init_db
from app.services import ocr_env, ocr_worker


@pytest.fixture(autouse=True)
def _reset_worker():
    """ocr_worker keeps a module-level queue + thread; isolate every test."""
    ocr_worker._reset_for_tests()
    yield
    ocr_worker._reset_for_tests()


@pytest.fixture
def db(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def _stroke(sid: str, x0: float, y0: float, w: float = 30.0, h: float = 20.0) -> dict:
    """A pen stroke whose bbox is exactly (x0, y0, x0+w, y0+h)."""
    return {
        "id": sid,
        "width": 3,
        "tool": "pen",
        "points": [
            {"x": x0, "y": y0},
            {"x": x0 + w / 2, "y": y0 + h},
            {"x": x0 + w, "y": y0 + h / 2},
        ],
    }


def _insert_notebook(
    db: sqlite3.Connection,
    nb_id: str,
    strokes: list[dict] | None,
    deleted: bool = False,
) -> None:
    ink = json.dumps({"strokes": strokes}) if strokes is not None else None
    db.execute(
        "INSERT INTO notebooks (id, title, doc, ink, created_at, updated_at, deleted_at) "
        "VALUES (?, 'T', '{}', ?, 1, 1, ?)",
        (nb_id, ink, 1 if deleted else None),
    )
    db.commit()


def _rows(db: sqlite3.Connection, nb_id: str) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT * FROM ink_index WHERE notebook_id = ? ORDER BY id", (nb_id,)
    ).fetchall()


def _ink_changes(db: sqlite3.Connection, nb_id: str) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT * FROM change_log WHERE entity_type = 'ink_index' AND entity_id = ? "
        "ORDER BY seq",
        (nb_id,),
    ).fetchall()


# ---------------------------------------------------------------------------
# reindex_notebook: the unit
# ---------------------------------------------------------------------------


class TestReindex:
    def test_two_word_notebook_indexes_into_two_rows_sharing_a_line_id(self, db):
        # Two strokes on one baseline, 50px apart (> 12px word gap) — one
        # line, two words. One infer call per LINE, not per word.
        _insert_notebook(db, "nb-1", [_stroke("s-a", 0, 0), _stroke("s-b", 80, 0)])
        calls: list = []

        def infer(img):
            calls.append(img)
            return "hello world"

        ocr_worker.reindex_notebook(db, "nb-1", infer=infer, now=1000)

        rows = _rows(db, "nb-1")
        assert len(rows) == 2
        assert len({r["line_id"] for r in rows}) == 1, "both words share the line"
        assert [r["word_text"] for r in rows] == ["hello", "world"]
        assert [r["word_text_lower"] for r in rows] == ["hello", "world"]
        assert all(r["model"] == ocr_env.MODEL_ID for r in rows)
        assert all(r["indexed_at"] == 1000 for r in rows)
        assert len(calls) == 1, "one render+infer per line"

        assert json.loads(rows[0]["stroke_ids_json"]) == ["s-a"]
        assert json.loads(rows[1]["stroke_ids_json"]) == ["s-b"]
        bbox = json.loads(rows[0]["bbox_json"])
        assert bbox == pytest.approx([0.0, 0.0, 30.0, 20.0])

        changes = _ink_changes(db, "nb-1")
        assert len(changes) == 1, "one change per notebook batch"
        assert changes[0]["op"] == "upsert"
        assert changes[0]["device_id"] == "server"

    def test_word_text_split_follows_x_order_not_stroke_id_order(self, db):
        # The LEFT word's stroke id sorts LAST alphabetically. If the split
        # followed stroke-id order the words would swap.
        strokes = [_stroke("a-right", 80, 0), _stroke("z-left", 0, 0)]
        _insert_notebook(db, "nb-x", strokes)

        ocr_worker.reindex_notebook(db, "nb-x", infer=lambda img: "alpha beta", now=1000)

        by_stroke = {
            json.loads(r["stroke_ids_json"])[0]: r["word_text"]
            for r in _rows(db, "nb-x")
        }
        assert by_stroke == {"z-left": "alpha", "a-right": "beta"}, (
            "text tokens must map to words left-to-right"
        )

    def test_editing_one_line_reindexes_only_that_line(self, db):
        # Two lines (y-centres 60px apart). Replacing line 2's stroke gives
        # line 2 a new line_id; line 1's rows must be left untouched —
        # indexed_at proves it (invalidation is line-granular).
        _insert_notebook(db, "nb-2", [_stroke("s-1", 0, 0), _stroke("s-2", 0, 60)])
        ocr_worker.reindex_notebook(db, "nb-2", infer=lambda img: "keep", now=1000)

        first = _rows(db, "nb-2")
        assert len(first) == 2
        line1 = next(r for r in first if json.loads(r["stroke_ids_json"]) == ["s-1"])
        old_line2 = next(r for r in first if json.loads(r["stroke_ids_json"]) == ["s-2"])

        # The edit: stroke s-2 is erased and redrawn as s-2b.
        new_ink = json.dumps(
            {"strokes": [_stroke("s-1", 0, 0), _stroke("s-2b", 0, 60)]}
        )
        db.execute("UPDATE notebooks SET ink = ? WHERE id = 'nb-2'", (new_ink,))
        db.commit()

        calls: list = []

        def infer(img):
            calls.append(img)
            return "edited"

        ocr_worker.reindex_notebook(db, "nb-2", infer=infer, now=2000)

        assert len(calls) == 1, "only the changed line is re-inferred"
        after = _rows(db, "nb-2")
        assert len(after) == 2
        line1_after = next(
            r for r in after if json.loads(r["stroke_ids_json"]) == ["s-1"]
        )
        assert line1_after["indexed_at"] == 1000, (
            "the unchanged line's rows must not be touched"
        )
        assert line1_after["word_text"] == "keep"
        assert line1_after["id"] == line1["id"]

        line2_after = next(
            r for r in after if json.loads(r["stroke_ids_json"]) == ["s-2b"]
        )
        assert line2_after["indexed_at"] == 2000
        assert line2_after["word_text"] == "edited"
        assert line2_after["line_id"] != old_line2["line_id"]

    def test_unchanged_notebook_is_not_reindexed_and_publishes_no_change(self, db):
        _insert_notebook(db, "nb-same", [_stroke("s-1", 0, 0)])
        ocr_worker.reindex_notebook(db, "nb-same", infer=lambda img: "once", now=1000)

        calls: list = []
        ocr_worker.reindex_notebook(
            db, "nb-same", infer=lambda img: calls.append(img) or "again", now=2000
        )

        assert calls == [], "no line changed: infer must not run"
        rows = _rows(db, "nb-same")
        assert [r["indexed_at"] for r in rows] == [1000]
        assert len(_ink_changes(db, "nb-same")) == 1, "no-op runs publish nothing"

    def test_per_line_infer_failure_records_error_rows_others_index_fine(self, db):
        # Lines are processed top-to-bottom; the first infer call blows up.
        _insert_notebook(db, "nb-err", [_stroke("s-top", 0, 0), _stroke("s-bot", 0, 60)])
        calls: list = []

        def infer(img):
            calls.append(img)
            if len(calls) == 1:
                raise RuntimeError("model exploded")
            return "ok"

        ocr_worker.reindex_notebook(db, "nb-err", infer=infer, now=1000)

        rows = _rows(db, "nb-err")
        assert len(rows) == 2, "the failing line must not kill the batch"
        by_stroke = {json.loads(r["stroke_ids_json"])[0]: r for r in rows}
        assert by_stroke["s-top"]["word_text"] == ""
        assert by_stroke["s-top"]["model"] == "error"
        assert by_stroke["s-bot"]["word_text"] == "ok"
        assert by_stroke["s-bot"]["model"] == ocr_env.MODEL_ID

    def test_deleted_notebook_purges_rows_and_publishes_a_delete(self, db):
        _insert_notebook(db, "nb-del", [_stroke("s-1", 0, 0)])
        ocr_worker.reindex_notebook(db, "nb-del", infer=lambda img: "gone", now=1000)
        assert len(_rows(db, "nb-del")) == 1

        db.execute("UPDATE notebooks SET deleted_at = 5 WHERE id = 'nb-del'")
        db.commit()
        ocr_worker.reindex_notebook(db, "nb-del", infer=lambda img: "x", now=2000)

        assert _rows(db, "nb-del") == []
        changes = _ink_changes(db, "nb-del")
        assert changes[-1]["op"] == "delete"

    def test_missing_or_inkless_notebook_is_a_quiet_noop(self, db):
        ocr_worker.reindex_notebook(db, "ghost", infer=lambda img: "x", now=1000)
        _insert_notebook(db, "nb-noink", None)
        ocr_worker.reindex_notebook(db, "nb-noink", infer=lambda img: "x", now=1000)

        count = db.execute("SELECT COUNT(*) AS n FROM ink_index").fetchone()["n"]
        assert count == 0
        assert _ink_changes(db, "ghost") == []
        assert _ink_changes(db, "nb-noink") == []

    def test_double_encoded_ink_still_indexes(self, db):
        # Old DBs in the wild: notebooks.ink holds json.dumps(json.dumps(...))
        # (the Task 3 backfill bug). The worker must peel the extra layer and
        # index anyway — 25 production notebooks silently no-op'd without it.
        inner = json.dumps({"strokes": [_stroke("s-a", 0, 0)]})
        db.execute(
            "INSERT INTO notebooks (id, title, doc, ink, created_at, updated_at) "
            "VALUES ('nb-dbl', 'T', '{}', ?, 1, 1)",
            (json.dumps(inner),),
        )
        db.commit()

        ocr_worker.reindex_notebook(db, "nb-dbl", infer=lambda img: "hello", now=1000)

        rows = _rows(db, "nb-dbl")
        assert len(rows) == 1, "double-encoded ink must still be indexed"
        assert rows[0]["word_text"] == "hello"

    def test_unparseable_ink_warns_instead_of_silent_noop(self, db, monkeypatch):
        # ink that never resolves to a dict must be LOUD: the silent
        # empty-notebook treatment is what hid the production bug.
        warnings: list = []

        class _Log:
            def __getattr__(self, name):
                def _record(event, **kw):
                    if name == "warning":
                        warnings.append((event, kw))

                return _record

        monkeypatch.setattr(ocr_worker, "log", _Log())
        db.execute(
            "INSERT INTO notebooks (id, title, doc, ink, created_at, updated_at) "
            "VALUES ('nb-junk', 'T', '{}', ?, 1, 1)",
            (json.dumps("this is not ink"),),
        )
        db.commit()

        ocr_worker.reindex_notebook(db, "nb-junk", infer=lambda img: "x", now=1000)

        assert _rows(db, "nb-junk") == [], "no rows from junk ink"
        assert any(
            event == "ocr_worker.ink_unparseable"
            and kw.get("notebook_id") == "nb-junk"
            for event, kw in warnings
        ), "unparseable ink must log a warning, never a silent no-op"


# ---------------------------------------------------------------------------
# run_inference: the subprocess boundary
# ---------------------------------------------------------------------------


def test_run_inference_raises_when_env_not_installed(temp_data_dir):
    with pytest.raises(RuntimeError, match="not installed"):
        ocr_worker.run_inference(Image.new("L", (32, 32), 255))


def test_run_inference_shells_to_the_venv_python(monkeypatch, tmp_path):
    # The stub stands in for ocr_infer.py; the test interpreter stands in for
    # the venv python. What is pinned: argv contract (--image <png>) and that
    # stdout comes back stripped.
    stub = tmp_path / "stub_infer.py"
    stub.write_text(
        "import sys\n"
        "assert '--image' in sys.argv\n"
        "path = sys.argv[sys.argv.index('--image') + 1]\n"
        "open(path, 'rb').close()\n"
        "print('stubbed text')\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(ocr_worker.ocr_env, "python_path", lambda: sys.executable)
    monkeypatch.setattr(ocr_worker, "_infer_script", lambda: stub)

    out = ocr_worker.run_inference(Image.new("L", (32, 32), 255))
    assert out == "stubbed text"


def test_run_inference_surfaces_subprocess_failure(monkeypatch, tmp_path):
    stub = tmp_path / "boom.py"
    stub.write_text("import sys; sys.exit(3)\n", encoding="utf-8")
    monkeypatch.setattr(ocr_worker.ocr_env, "python_path", lambda: sys.executable)
    monkeypatch.setattr(ocr_worker, "_infer_script", lambda: stub)

    with pytest.raises(RuntimeError, match="exited 3"):
        ocr_worker.run_inference(Image.new("L", (32, 32), 255))


# ---------------------------------------------------------------------------
# queue, backfill, worker gating
# ---------------------------------------------------------------------------


def test_backfill_scan_enqueues_only_unindexed_live_inked_notebooks(db):
    _insert_notebook(db, "nb-indexed", [_stroke("s-1", 0, 0)])
    db.execute(
        "INSERT INTO ink_index VALUES ('l1:000', 'nb-indexed', 'l1', 'hi', 'hi', "
        "'[0,0,1,1]', '[\"s-1\"]', 'm', 1)"
    )
    _insert_notebook(db, "nb-pending", [_stroke("s-2", 0, 0)])
    _insert_notebook(db, "nb-deleted", [_stroke("s-3", 0, 0)], deleted=True)
    _insert_notebook(db, "nb-inkless", None)
    db.commit()

    found = ocr_worker.backfill_scan(db)

    assert found == ["nb-pending"]
    assert ocr_worker.pending() == ["nb-pending"]


def test_enqueue_deduplicates(db):
    ocr_worker.enqueue("nb-1")
    ocr_worker.enqueue("nb-1")
    ocr_worker.enqueue("nb-2")
    assert ocr_worker.pending() == ["nb-1", "nb-2"]


def test_worker_starts_only_when_ocr_env_is_installed(temp_data_dir):
    init_db(str(temp_data_dir))
    assert ocr_worker.start_worker_if_installed() is None
    assert not ocr_worker.worker_running()

    # Fake a verified install: marker + venv interpreter files.
    env = Path(temp_data_dir) / "ocr-env"
    for cand in (env / "venv" / "Scripts" / "python.exe", env / "venv" / "bin" / "python"):
        cand.parent.mkdir(parents=True, exist_ok=True)
        cand.write_text("")
    (env / "verified.json").write_text(
        json.dumps({"flavour": "cpu", "model": ocr_env.MODEL_ID}), encoding="utf-8"
    )

    try:
        thread = ocr_worker.start_worker_if_installed()
        assert thread is not None
        deadline = time.time() + 5
        while not ocr_worker.worker_running() and time.time() < deadline:
            time.sleep(0.01)
        assert ocr_worker.worker_running()
    finally:
        ocr_worker.stop_worker()
    assert not ocr_worker.worker_running()


# ---------------------------------------------------------------------------
# ocr_infer.py: what can be tested without torch
# ---------------------------------------------------------------------------


def test_ocr_infer_exists_at_the_path_the_installer_verifies():
    from app import ocr_infer
    from app.services.ocr_env import _ocr_infer_path

    assert _ocr_infer_path().exists(), "the installer's verify step needs this file"
    assert Path(ocr_infer.__file__).resolve() == _ocr_infer_path().resolve()


def test_ocr_infer_derives_models_dir_from_the_venv_interpreter():
    from app.ocr_infer import default_models_dir

    win = default_models_dir("C:/data/ocr-env/venv/Scripts/python.exe")
    posix = default_models_dir("/data/ocr-env/venv/bin/python")
    assert win.name == "models" and win.parent.name == "ocr-env"
    assert posix.name == "models" and posix.parent.name == "ocr-env"


# ---------------------------------------------------------------------------
# GET /v1/ocr/status
# ---------------------------------------------------------------------------


@pytest.fixture
def api_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    from app.api.ocr import router as ocr_router

    app = FastAPI()
    app.include_router(ocr_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_status_requires_auth(api_client):
    cli, _ = api_client
    assert cli.get("/v1/ocr/status").status_code == 401


def test_status_reports_counts_and_backlog(api_client, temp_data_dir):
    cli, token = api_client
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        _insert_notebook(conn, "nb-a", [_stroke("s-1", 0, 0)])
        conn.executescript(
            """
            INSERT INTO ink_index VALUES
              ('l1:000', 'nb-a', 'l1', 'hello', 'hello', '[0,0,1,1]', '["s-1"]', 'm', 1),
              ('l1:001', 'nb-a', 'l1', 'world', 'world', '[0,0,1,1]', '["s-1"]', 'm', 1),
              ('l2:000', 'nb-a', 'l2', '', '', '[0,0,1,1]', '["s-1"]', 'error', 1);
            """
        )
        _insert_notebook(conn, "nb-b", [_stroke("s-2", 0, 0)])  # backlog
        _insert_notebook(conn, "nb-c", [_stroke("s-3", 0, 0)], deleted=True)
        conn.commit()
    finally:
        conn.close()

    ocr_worker.enqueue("nb-b")

    body = cli.get("/v1/ocr/status", headers=_auth(token)).json()
    assert body["installed"] is False
    assert body["worker_running"] is False
    assert body["indexed_notebooks"] == 1
    assert body["indexed_words"] == 2
    assert body["error_words"] == 1
    assert body["backlog"] == 1, "only nb-b: live, inked, no rows yet"
    assert body["queue_depth"] == 1
