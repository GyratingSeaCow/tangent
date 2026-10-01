# SPDX-License-Identifier: AGPL-3.0-or-later
"""v1.41 Morning Brief: aggregate input, postprocess, cache, scheduler, API.

Inference is ALWAYS faked here (fakes close the API contract). Real-model
output quality (no-invention on empty/heavy/adversarial days) is a LIVE-E2E
item on the container — it cannot be proven by these tests.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api import morning_brief as api
from app.db import init_db
from app.main import create_app
from app.services import morning_brief, summarizer_env, summarizer_worker

DAY = date(2026, 10, 2)


def _ts(day: date, hour: int) -> int:
    return int(datetime(day.year, day.month, day.day, hour).astimezone().timestamp())


@pytest.fixture
def db(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


@pytest.fixture
def installed(monkeypatch):
    monkeypatch.setattr(summarizer_env, "python_path", lambda: "/fake/python")


def _enable(db: sqlite3.Connection) -> None:
    summarizer_worker.set_summaries_enabled(db, True)


def _dump(db, dump_id, created_at, title="T", mode="brain_dump", summary=None,
          transcript=None, deleted=False):
    db.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, "
        "duration_seconds, title, transcript, summary, deleted_at) "
        "VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)",
        (dump_id, dump_id, created_at, created_at, mode, title, transcript,
         summary, created_at if deleted else None),
    )
    db.commit()


def _todo(db, todo_id, text, due=None, done=False, deleted=False):
    db.execute(
        "INSERT INTO todos (id, text, done_at, due_date, created_at, updated_at, "
        "deleted_at) VALUES (?, ?, ?, ?, '2026-10-01', '2026-10-01', ?)",
        (todo_id, text, "2026-10-01" if done else None, due,
         "2026-10-01" if deleted else None),
    )
    db.commit()


def _change(db, entity_type, entity_id, payload):
    db.execute(
        "INSERT INTO change_log (entity_type, entity_id, op, device_id, payload, "
        "created_at) VALUES (?, ?, 'upsert', 'dev', ?, 0)",
        (entity_type, entity_id, json.dumps(payload)),
    )
    db.commit()


# --- aggregate input ----------------------------------------------------------


def test_input_aggregates_yesterday_due_today_and_pins(db):
    yesterday = DAY - timedelta(days=1)
    _dump(db, "d1", _ts(yesterday, 9), "Vendor call", "meeting",
          summary="Launch moved to the 14th.", transcript="ignored")
    _dump(db, "d2", _ts(yesterday, 18), "Garden", transcript="Raised beds.")
    _dump(db, "d-old", _ts(DAY - timedelta(days=3), 9), "Too old")
    _dump(db, "d-today", _ts(DAY, 1), "Today already")
    _dump(db, "d-gone", _ts(yesterday, 10), "Deleted", deleted=True)
    _todo(db, "t1", "Send checklist", due="2026-10-02")
    _todo(db, "t-done", "Done one", due="2026-10-02", done=True)
    _todo(db, "t-later", "Later", due="2026-10-09")
    _todo(db, "t-del", "Deleted todo", due="2026-10-02", deleted=True)
    db.execute(
        "INSERT INTO notebooks (id, title, doc, created_at, updated_at) "
        "VALUES ('n1', 'Roadmap', '{}', 0, 0)"
    )
    _change(db, "notebook", "n1", {"title": "Roadmap", "pinned": True})
    # A later server republish WITHOUT the key must not unpin it.
    _change(db, "notebook", "n1", {"title": "Roadmap"})
    _change(db, "dump", "d2", {"pinned": True})
    _change(db, "dump", "d2", {"pinned": False})  # unpinned later

    text = morning_brief.build_input(db, DAY)

    assert text == (
        "## Captured yesterday\n"
        "- Vendor call (meeting): Launch moved to the 14th.\n"
        "- Garden (brain dump): Raised beds.\n"
        "## Due today\n"
        "- Send checklist\n"
        "## Pinned\n"
        "- Roadmap (notebook)"
    )


def test_empty_day_input_is_empty(db):
    assert morning_brief.build_input(db, DAY) == ""


def test_long_bodies_are_clipped(db):
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "Long",
          transcript="word " * 2000)
    line = morning_brief.build_input(db, DAY).splitlines()[1]
    assert len(line) < morning_brief.MAX_ITEM_CHARS + 40
    assert line.endswith("…")


# --- postprocess ---------------------------------------------------------------


def test_postprocess_strips_none_placeholders_and_empty_highlights():
    raw = "Output:\nA quiet day.\n\n**Highlights**\n- None\n"
    assert morning_brief.postprocess_brief(raw) == "A quiet day."


def test_postprocess_keeps_real_highlights():
    raw = "Busy day.\n\n**Highlights**\n- None identified\n- Launch moved."
    assert morning_brief.postprocess_brief(raw) == (
        "Busy day.\n\n**Highlights**\n- Launch moved."
    )


# --- generate / cache ---------------------------------------------------------


def test_generate_is_gated_on_install_and_toggle(db, monkeypatch):
    calls = []
    infer = lambda *a: calls.append(a) or "x"  # noqa: E731
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="a")
    assert morning_brief.generate(db, DAY, infer=infer) is False  # not installed
    monkeypatch.setattr(summarizer_env, "python_path", lambda: "/fake/python")
    assert morning_brief.generate(db, DAY, infer=infer) is False  # disabled
    assert calls == []
    assert morning_brief.get_brief(db, DAY) is None


def test_generate_caches_and_is_idempotent_per_date(db, installed):
    _enable(db)
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="alpha")
    seen = []

    def infer(key, text, prompt):
        seen.append((key, text, prompt))
        return f"Brief {len(seen)}\n\n**Highlights**\n- None"

    assert morning_brief.generate(db, DAY, infer=infer, now=111) is True
    assert morning_brief.generate(db, DAY, infer=infer, now=222) is True
    row = morning_brief.get_brief(db, DAY)
    assert len(seen) == 1, "second call must hit the cache"
    assert (row["brief_md"], row["generated_at"]) == ("Brief 1", 111)
    assert row["model"] == summarizer_worker.MODEL_STEM
    assert seen[0][0] == "morning-brief:2026-10-02"
    assert "## Captured yesterday" in seen[0][1]
    assert seen[0][2].count("Example:") == 1
    # Explicit regenerate replaces it.
    assert morning_brief.generate(db, DAY, infer=infer, force=True, now=333)
    assert morning_brief.get_brief(db, DAY)["brief_md"] == "Brief 2"


def test_empty_day_never_reaches_the_model(db, installed):
    _enable(db)

    def infer(*_):
        raise AssertionError("an empty day must not be sent to the model")

    assert morning_brief.generate(db, DAY, infer=infer) is True
    row = morning_brief.get_brief(db, DAY)
    assert row["brief_md"] == morning_brief.EMPTY_DAY_BRIEF
    assert row["model"] == morning_brief.EMPTY_DAY_MODEL


@pytest.mark.parametrize("output", ["", "- None\n", "**Highlights**\n- None"])
def test_empty_model_output_stores_nothing(db, installed, output):
    _enable(db)
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="a")
    assert morning_brief.generate(db, DAY, infer=lambda *_: output) is False
    assert morning_brief.get_brief(db, DAY) is None


def test_inference_failure_is_swallowed(db, installed):
    _enable(db)
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="a")

    def boom(*_):
        raise RuntimeError("child died")

    assert morning_brief.generate(db, DAY, infer=boom) is False
    assert morning_brief.get_brief(db, DAY) is None


# --- scheduler ----------------------------------------------------------------


def _at(hour: int, minute: int = 0) -> datetime:
    return datetime(DAY.year, DAY.month, DAY.day, hour, minute).astimezone()


def test_tick_waits_for_0500_then_generates_once(db, installed):
    _enable(db)
    calls = []
    infer = lambda *a: calls.append(a) or "Brief."  # noqa: E731
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="a")
    assert morning_brief.tick(db, _at(4, 59), infer=infer) is False
    assert calls == []
    assert morning_brief.tick(db, _at(5, 0), infer=infer) is True
    assert morning_brief.tick(db, _at(5, 1), infer=infer) is False
    assert morning_brief.tick(db, _at(13), infer=infer) is False
    assert len(calls) == 1


def test_tick_catches_up_after_a_late_boot(db, installed):
    _enable(db)
    assert morning_brief.tick(db, _at(11), infer=lambda *_: "x") is True
    assert morning_brief.get_brief(db, DAY) is not None


def test_tick_backs_off_and_caps_failed_attempts(db, installed):
    _enable(db)
    _dump(db, "d1", _ts(DAY - timedelta(days=1), 9), "A", transcript="a")
    calls = []

    def boom(*a):
        calls.append(a)
        raise RuntimeError("no")

    clock = [1000.0]
    mono = lambda: clock[0]  # noqa: E731
    assert morning_brief.tick(db, _at(5), infer=boom, monotonic=mono) is False
    assert morning_brief.tick(db, _at(5, 1), infer=boom, monotonic=mono) is False
    assert len(calls) == 1, "inside the back-off window"
    for _ in range(5):
        clock[0] += morning_brief.RETRY_AFTER_S
        morning_brief.tick(db, _at(6), infer=boom, monotonic=mono)
    assert len(calls) == morning_brief.MAX_ATTEMPTS_PER_DAY


def test_tick_never_raises(db, installed, monkeypatch):
    _enable(db)

    def broken(*_a, **_k):
        raise sqlite3.OperationalError("db locked")

    monkeypatch.setattr(morning_brief, "get_brief", broken)
    assert morning_brief.tick(db, _at(6), infer=lambda *_: "x") is False


def test_lifespan_starts_and_stops_the_scheduler(temp_data_dir, monkeypatch):
    events = []
    monkeypatch.setattr(morning_brief, "start_scheduler", lambda: events.append("start"))
    monkeypatch.setattr(morning_brief, "stop_scheduler", lambda: events.append("stop"))
    with TestClient(create_app()):
        assert events == ["start"]
    assert events == ["start", "stop"]


def test_scheduler_start_failure_never_breaks_startup(temp_data_dir, monkeypatch):
    def boom():
        raise RuntimeError("thread refused")

    monkeypatch.setattr(morning_brief, "start_scheduler", boom)
    with TestClient(create_app()) as cli:
        assert cli.get("/v1/server/info").status_code < 500


# --- API ----------------------------------------------------------------------


@pytest.fixture
def client(temp_data_dir: Path, monkeypatch):
    monkeypatch.setattr(summarizer_env, "probe_gpu_visible", lambda: False)
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        conn = sqlite3.connect(temp_data_dir / "tangent.db")
        conn.row_factory = sqlite3.Row
        try:
            yield cli, {"Authorization": f"Bearer {token}"}, conn
        finally:
            conn.close()


def test_get_requires_auth(client):
    cli, _, _ = client
    assert cli.get("/v1/morning-brief").status_code == 401


def test_get_409_not_installed_with_the_load_bearing_detail(client):
    cli, auth, _ = client
    resp = cli.get("/v1/morning-brief?date=2026-10-02", headers=auth)
    assert resp.status_code == 409
    assert resp.json()["detail"] == "Summarizer environment is not installed"
    assert api.DETAIL_NOT_INSTALLED == "Summarizer environment is not installed"


def test_get_409_disabled_hides_even_a_cached_brief(client, installed):
    cli, auth, conn = client
    conn.execute(
        "INSERT INTO morning_briefs VALUES ('2026-10-02', 'Old.', 'm', 1)"
    )
    conn.commit()
    resp = cli.get("/v1/morning-brief?date=2026-10-02", headers=auth)
    assert resp.status_code == 409
    assert resp.json()["detail"] == "AI summaries are disabled"


def test_get_404_then_200(client, installed):
    cli, auth, conn = client
    _enable(conn)
    resp = cli.get("/v1/morning-brief?date=2026-10-02", headers=auth)
    assert resp.status_code == 404
    conn.execute(
        "INSERT INTO morning_briefs VALUES ('2026-10-02', 'Hello.', 'qwen', 42)"
    )
    conn.commit()
    resp = cli.get("/v1/morning-brief?date=2026-10-02", headers=auth)
    assert resp.status_code == 200
    assert resp.json() == {
        "date": "2026-10-02",
        "brief_md": "Hello.",
        "generated_at": 42,
        "model": "qwen",
    }


def test_get_rejects_a_malformed_date(client, installed):
    cli, auth, conn = client
    _enable(conn)
    assert cli.get("/v1/morning-brief?date=tomorrow", headers=auth).status_code == 422


def test_regenerate_is_gated_and_runs_in_background(client, installed, monkeypatch):
    cli, auth, conn = client
    started = []
    monkeypatch.setattr(morning_brief, "generate_now", lambda day: started.append(day))
    resp = cli.post("/v1/morning-brief/generate?date=2026-10-02", headers=auth)
    assert resp.status_code == 409
    _enable(conn)
    resp = cli.post("/v1/morning-brief/generate?date=2026-10-02", headers=auth)
    assert resp.status_code == 202
    assert resp.json() == {"date": "2026-10-02", "status": "generating"}
    for _ in range(100):
        if started:
            break
        import time

        time.sleep(0.02)
    assert started == [DAY]


def test_morning_brief_is_not_a_summarize_template(client, installed):
    cli, auth, conn = client
    _dump(conn, "d1", 1, "A", transcript="a")
    resp = cli.post(
        "/v1/dumps/d1/summarize", json={"template": "morning_brief"}, headers=auth
    )
    assert resp.status_code == 422
    templates = cli.get("/v1/summaries/templates", headers=auth).json()["templates"]
    assert "morning_brief" not in [t["id"] for t in templates]
