# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Calendar worker contract; Google HTTP is faked in-process."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from app.db import init_db
from app.services import google_calendar_worker as w


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
