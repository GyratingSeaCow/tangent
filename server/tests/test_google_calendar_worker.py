# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Calendar worker contract; Google HTTP is faked in-process."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from app.db import init_db
from app.services import google_calendar_worker as w
from app.services import google_tasks_worker as tasks_worker


def _db(tmp_path: Path) -> sqlite3.Connection:
    init_db(str(tmp_path))
    conn = sqlite3.connect(tmp_path / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _seed(conn: sqlite3.Connection, **overrides: object) -> None:
    row: dict[str, object] = {
        "id": "ev-1",
        "title": "Dentist",
        "start": "2026-10-01T14:00:00",
        "end_": "2026-10-01T15:00:00",
        "all_day": 0,
        "time_zone": "America/New_York",
        "needs_date": 0,
        "source": "voice",
        "source_ref": "dump-1",
        "created_at": "2026-09-28T20:00:00+00:00",
        "updated_at": "2026-09-28T20:00:00+00:00",
    }
    row.update(overrides)
    conn.execute(
        f"INSERT INTO calendar_events ({','.join(row)}) "
        f"VALUES ({','.join('?' * len(row))})",
        tuple(row.values()),
    )
    conn.commit()


class Response:
    def __init__(self, body: dict[str, Any], status_code: int):
        self._body = body
        self.status_code = status_code

    def json(self) -> dict[str, Any]:
        return self._body


class Recorder:
    def __init__(self, replies: list[tuple[dict[str, Any], int]]):
        self.calls: list[tuple[str, str, dict[str, Any] | None, dict[str, Any]]] = []
        self.replies = list(replies)

    def __call__(self, method: str, url: str, **kwargs: Any) -> Response:
        self.calls.append((method, url, kwargs.get("json"), kwargs))
        body, code = self.replies.pop(0)
        return Response(body, code)


def test_timed_event_body_has_datetime_and_timezone() -> None:
    body = w.event_to_google(
        {
            "title": "Dentist",
            "start": "2026-10-01T14:00:00",
            "end_": "2026-10-01T15:00:00",
            "all_day": 0,
            "time_zone": "America/New_York",
            "id": "ev-1",
            "source_ref": "dump-1",
        }
    )
    assert body["start"] == {
        "dateTime": "2026-10-01T14:00:00",
        "timeZone": "America/New_York",
    }
    assert body["end"]["dateTime"] == "2026-10-01T15:00:00"
    assert body["end"]["timeZone"] == "America/New_York"
    assert body["extendedProperties"]["private"]["tangent_id"] == "ev-1"
    assert "tangent://dump/dump-1" in body["description"]


def test_legacy_abbreviation_time_zone_is_sanitized() -> None:
    """Rows written by pre-fix Linux clients stored 'EDT', not IANA names."""
    body = w.event_to_google(
        {
            "title": "Dentist",
            "start": "2026-10-01T14:00:00",
            "end_": "2026-10-01T15:00:00",
            "all_day": 0,
            "time_zone": "EDT",
            "id": "ev-3",
            "source_ref": "dump-1",
        }
    )
    assert body["start"]["timeZone"] == "America/New_York"
    assert body["end"]["timeZone"] == "America/New_York"


def test_unknown_abbreviation_falls_back_to_utc() -> None:
    assert w._sanitize_time_zone("XYZT") == "UTC"
    assert w._sanitize_time_zone("Europe/Paris") == "Europe/Paris"


def test_all_day_event_body_uses_date_only() -> None:
    body = w.event_to_google(
        {
            "title": "Trip",
            "start": "2026-10-01",
            "end_": "2026-10-02",
            "all_day": 1,
            "time_zone": "America/New_York",
            "id": "ev-2",
            "source_ref": "dump-1",
        }
    )
    assert body["start"] == {"date": "2026-10-01"}
    assert body["end"] == {"date": "2026-10-02"}


def test_push_inserts_new_and_stores_ids(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    _seed(conn)
    rec = Recorder(
        [
            (
                {
                    "id": "g1",
                    "htmlLink": "https://cal/g1",
                    "updated": "2026-09-28T20:00:05.000Z",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(conn, "tok") == 1
    method, url, _, _ = rec.calls[0]
    assert method == "POST" and url.endswith("/calendars/primary/events")
    row = conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert (row["google_event_id"], row["google_html_link"]) == (
        "g1",
        "https://cal/g1",
    )
    assert conn.execute(
        "SELECT count(*) FROM change_log WHERE entity_type='calendar_event'"
    ).fetchone()[0] == 1


def test_push_patches_changed_existing(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    _seed(
        conn,
        google_event_id="g1",
        google_updated="2026-09-28T19:00:00Z",
        updated_at="2026-09-28T20:00:00+00:00",
    )
    rec = Recorder(
        [
            (
                {
                    "id": "g1",
                    "htmlLink": "https://cal/g1",
                    "updated": "2026-09-28T20:00:05.000Z",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(conn, "tok") == 1
    assert rec.calls[0][0] == "PATCH"
    assert rec.calls[0][1].endswith("/events/g1")


def test_push_skips_unchanged(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    _seed(conn, google_event_id="g1", google_updated="2026-09-28T21:00:00Z")
    rec = Recorder([])
    monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(conn, "tok") == 0
    assert rec.calls == []


def test_delete_removes_on_google_and_tolerates_gone(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    _seed(
        conn,
        google_event_id="g1",
        deleted_at="2026-09-28T22:00:00+00:00",
    )
    _seed(
        conn,
        id="ev-2",
        google_event_id="g2",
        deleted_at="2026-09-28T22:00:00+00:00",
    )
    rec = Recorder([({}, 204), ({"error": {"code": 410}}, 410)])
    monkeypatch.setattr(w, "_request", rec)
    assert w.delete_events(conn, "tok") == 2
    assert [call[0] for call in rec.calls] == ["DELETE", "DELETE"]
    assert conn.execute(
        "SELECT count(*) FROM calendar_events WHERE google_event_id IS NOT NULL"
    ).fetchone()[0] == 0


def test_pull_applies_google_newer_and_clears_needs_date(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    _seed(
        conn,
        google_event_id="g1",
        google_updated="2026-09-28T20:00:00Z",
        start="2026-09-28",
        end_="2026-09-29",
        all_day=1,
        needs_date=1,
    )
    rec = Recorder(
        [
            (
                {
                    "items": [
                        {
                            "id": "g1",
                            "status": "confirmed",
                            "summary": "Dentist",
                            "updated": "2026-09-28T21:00:00.000Z",
                            "start": {"date": "2026-10-02"},
                            "end": {"date": "2026-10-03"},
                            "htmlLink": "https://cal/g1",
                            "extendedProperties": {
                                "private": {"tangent_id": "ev-1"}
                            },
                        }
                    ],
                    "nextSyncToken": "tok-1",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(conn, "tok") == 1
    row = conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert (row["start"], row["end_"], row["needs_date"]) == (
        "2026-10-02",
        "2026-10-03",
        0,
    )
    assert conn.execute(
        "SELECT calendar_sync_token FROM google_tasks_link WHERE id=1"
    ).fetchone()[0] == "tok-1"
    assert conn.execute(
        "SELECT count(*) FROM change_log WHERE entity_type='calendar_event'"
    ).fetchone()[0] == 1


def test_pull_title_only_change_keeps_needs_date_flag(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    _seed(
        conn,
        google_event_id="g1",
        google_updated="2026-09-28T20:00:00Z",
        start="2026-09-28",
        end_="2026-09-29",
        all_day=1,
        needs_date=1,
    )
    rec = Recorder(
        [
            (
                {
                    "items": [
                        {
                            "id": "g1",
                            "status": "confirmed",
                            "summary": "Renamed",
                            "updated": "2026-09-28T21:00:00Z",
                            "start": {"date": "2026-09-28"},
                            "end": {"date": "2026-09-29"},
                            "extendedProperties": {
                                "private": {"tangent_id": "ev-1"}
                            },
                        }
                    ],
                    "nextSyncToken": "tok-2",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(conn, "tok") == 1
    row = conn.execute(
        "SELECT title, needs_date FROM calendar_events WHERE id='ev-1'"
    ).fetchone()
    assert tuple(row) == ("Renamed", 1)


def test_pull_ignores_foreign_events(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    rec = Recorder(
        [
            (
                {
                    "items": [
                        {
                            "id": "zz",
                            "status": "confirmed",
                            "summary": "Not ours",
                            "updated": "2026-09-28T21:00:00.000Z",
                            "start": {"date": "2026-10-02"},
                            "end": {"date": "2026-10-03"},
                        }
                    ],
                    "nextSyncToken": "t",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(conn, "tok") == 0
    assert conn.execute("SELECT count(*) FROM calendar_events").fetchone()[0] == 0


def test_pull_cancelled_soft_deletes(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    _seed(
        conn,
        google_event_id="g1",
        google_updated="2026-09-28T20:00:00Z",
    )
    rec = Recorder(
        [
            (
                {
                    "items": [
                        {
                            "id": "g1",
                            "status": "cancelled",
                            "updated": "2026-09-28T21:00:00.000Z",
                            "extendedProperties": {
                                "private": {"tangent_id": "ev-1"}
                            },
                        }
                    ],
                    "nextSyncToken": "t",
                },
                200,
            )
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(conn, "tok") == 1
    assert conn.execute(
        "SELECT deleted_at FROM calendar_events WHERE id='ev-1'"
    ).fetchone()[0] is not None
    change = conn.execute(
        "SELECT op FROM change_log WHERE entity_type='calendar_event'"
    ).fetchone()
    assert change["op"] == "delete"


def test_pull_uses_sync_token_and_recovers_once_from_410(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    conn.execute(
        "INSERT INTO google_tasks_link (id, status, calendar_sync_token) "
        "VALUES (1, 'connected', 'expired')"
    )
    conn.commit()
    rec = Recorder(
        [
            ({"error": {"code": 410}}, 410),
            ({"items": [], "nextSyncToken": "fresh"}, 200),
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(conn, "tok") == 0
    assert rec.calls[0][3]["params"]["syncToken"] == "expired"
    assert "syncToken" not in rec.calls[1][3]["params"]
    assert conn.execute(
        "SELECT calendar_sync_token FROM google_tasks_link WHERE id=1"
    ).fetchone()[0] == "fresh"


def test_scope_gate_marks_reauth_and_skips_calendar(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    _seed(conn)
    conn.execute(
        "INSERT OR REPLACE INTO google_tasks_link "
        "(id, status, granted_scope) VALUES "
        "(1, 'connected', 'https://www.googleapis.com/auth/tasks openid email')"
    )
    conn.commit()
    rec = Recorder(
        [
            (
                {
                    "id": "g1",
                    "htmlLink": "https://cal/g1",
                    "updated": "2026-09-28T20:00:05Z",
                },
                200,
            ),
            ({"items": [], "nextSyncToken": "scope-proof"}, 200),
        ]
    )
    monkeypatch.setattr(w, "_request", rec)
    stats = w.run_calendar_cycle(conn, "tok")
    assert rec.calls == [] and stats.pushed == 0
    row = conn.execute(
        "SELECT status, last_error FROM google_tasks_link WHERE id=1"
    ).fetchone()
    assert row["status"] == "reauth_required"
    assert row["last_error"] == "Google Calendar permission not granted — Reconnect"


def test_calendar_cycle_pulls_before_any_local_event(tmp_path: Path, monkeypatch) -> None:
    conn = _db(tmp_path)
    conn.execute(
        "INSERT OR REPLACE INTO google_tasks_link (id, status, granted_scope) "
        "VALUES (1, 'connected', ?)",
        (w.CALENDAR_SCOPE,),
    )
    conn.commit()
    rec = Recorder([({"items": [], "nextSyncToken": "first-token"}, 200)])
    monkeypatch.setattr(w, "_request", rec)

    stats = w.run_calendar_cycle(conn, "tok")

    assert stats == w.CalendarStats()
    assert len(rec.calls) == 1
    assert rec.calls[0][0:2] == ("GET", w.CAL_BASE)
    assert conn.execute(
        "SELECT calendar_sync_token FROM google_tasks_link WHERE id=1"
    ).fetchone()[0] == "first-token"


def test_tasks_keep_running_while_calendar_waits_for_reconnect(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    conn.execute(
        "INSERT OR REPLACE INTO google_tasks_link "
        "(id, client_id, client_secret, refresh_token, access_token, "
        "access_expires_at, tasklist_id, status, granted_scope) VALUES "
        "(1, 'c', 's', 'refresh', 'access', 2000000000, 'list-1', "
        "'connected', 'https://www.googleapis.com/auth/tasks')"
    )
    conn.commit()
    task_cycles: list[str] = []

    def ensure_lists(*_args, **_kwargs):
        task_cycles.append("tasks")
        return {"list-1": None}

    monkeypatch.setattr(tasks_worker, "ensure_lists", ensure_lists)
    monkeypatch.setattr(tasks_worker, "_push", lambda *_args, **_kwargs: (0, []))
    monkeypatch.setattr(tasks_worker, "_pull_all", lambda *_args, **_kwargs: 0)
    rec = Recorder([])
    monkeypatch.setattr(w, "_request", rec)

    assert tasks_worker.run_cycle(conn) == (0, 0)
    assert tasks_worker.run_cycle_if_connected(conn) is True
    assert task_cycles == ["tasks", "tasks"]
    assert rec.calls == []
    row = conn.execute(
        "SELECT status, last_error, last_cal_pushed, last_cal_pulled "
        "FROM google_tasks_link WHERE id=1"
    ).fetchone()
    assert tuple(row) == (
        "reauth_required",
        "Google Calendar permission not granted — Reconnect",
        0,
        0,
    )


def test_successful_calendar_push_count_survives_later_pull_failure(
    tmp_path: Path, monkeypatch
) -> None:
    conn = _db(tmp_path)
    _seed(conn)
    conn.execute(
        "INSERT OR REPLACE INTO google_tasks_link "
        "(id, client_id, client_secret, refresh_token, access_token, "
        "access_expires_at, tasklist_id, status, granted_scope) VALUES "
        "(1, 'c', 's', 'refresh', 'access', 2000000000, 'list-1', "
        "'connected', ?)",
        (f"https://www.googleapis.com/auth/tasks {w.CALENDAR_SCOPE}",),
    )
    conn.commit()
    monkeypatch.setattr(
        tasks_worker, "ensure_lists", lambda *_args, **_kwargs: {"list-1": None}
    )
    monkeypatch.setattr(tasks_worker, "_push", lambda *_args, **_kwargs: (0, []))
    monkeypatch.setattr(tasks_worker, "_pull_all", lambda *_args, **_kwargs: 0)

    def calendar_request(method: str, _url: str, **_kwargs: Any) -> Response:
        if method == "POST":
            return Response(
                {
                    "id": "g1",
                    "htmlLink": "https://cal/g1",
                    "updated": "2026-09-28T20:00:05Z",
                },
                200,
            )
        raise tasks_worker.GoogleTasksError("calendar pull failed")

    monkeypatch.setattr(w, "_request", calendar_request)

    assert tasks_worker.run_cycle(conn) == (0, 0)
    row = conn.execute(
        "SELECT status, last_cal_pushed, last_cal_pulled FROM google_tasks_link "
        "WHERE id=1"
    ).fetchone()
    assert tuple(row) == ("error", 1, 0)
