# SPDX-License-Identifier: AGPL-3.0-or-later
"""Server-side calendar event sync contract."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.api.sync import _apply_calendar_event, _calendar_event_payload
from app.db import init_db
from app.models import SyncChange
from app.services.change_log import record_change


def _conn(tmp_path: Path) -> sqlite3.Connection:
    init_db(str(tmp_path))
    conn = sqlite3.connect(tmp_path / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _change(op: str = "upsert", **payload: object) -> SyncChange:
    base: dict[str, object] = {
        "id": "ev-1",
        "title": "Dentist",
        "start": "2026-10-01T14:00:00",
        "end": "2026-10-01T15:00:00",
        "all_day": 0,
        "time_zone": "America/New_York",
        "needs_date": 0,
        "source": "voice",
        "source_ref": "dump-1",
        "created_at": "2026-09-28T20:00:00+00:00",
        "updated_at": "2026-09-28T20:00:00+00:00",
        "capture_fingerprint": "should-not-be-stored",
    }
    base.update(payload)
    return SyncChange(
        entity_type="calendar_event",
        entity_id="ev-1",
        op=op,
        payload=None if op == "delete" else base,
    )


def test_upsert_stores_row_and_drops_client_only_field(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    changed, payload = _apply_calendar_event(conn, _change(), 1)
    row = conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert changed and row["title"] == "Dentist"
    assert row["end_"] == "2026-10-01T15:00:00"
    assert "capture_fingerprint" not in row.keys()
    assert payload is not None
    assert payload["end"] == "2026-10-01T15:00:00"
    assert "end_" not in payload and "capture_fingerprint" not in payload


def test_server_only_fields_preserved_across_device_upsert(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    _apply_calendar_event(conn, _change(), 1)
    conn.execute(
        "UPDATE calendar_events SET google_event_id='g1', "
        "google_html_link='https://x', google_updated='2026-09-28T20:01:00Z' "
        "WHERE id='ev-1'"
    )
    _apply_calendar_event(
        conn,
        _change(
            title="Dentist (moved)",
            updated_at="2026-09-28T20:05:00+00:00",
            google_event_id="CLIENT-LIES",
            google_html_link="https://client-lies",
            google_updated="2099-01-01T00:00:00Z",
        ),
        2,
    )
    row = conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert row["google_event_id"] == "g1"
    assert row["google_html_link"] == "https://x"
    assert row["google_updated"] == "2026-09-28T20:01:00Z"
    assert row["title"] == "Dentist (moved)"


def test_stale_write_dropped(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    _apply_calendar_event(
        conn, _change(updated_at="2026-09-28T21:00:00+00:00"), 1
    )
    changed, _ = _apply_calendar_event(
        conn,
        _change(title="old", updated_at="2026-09-28T20:00:00+00:00"),
        2,
    )
    assert changed is False
    assert conn.execute(
        "SELECT title FROM calendar_events WHERE id='ev-1'"
    ).fetchone()[0] == "Dentist"


def test_delete_soft_deletes(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    _apply_calendar_event(conn, _change(), 1)
    changed, payload = _apply_calendar_event(
        conn, _change(op="delete"), 2_000_000_000
    )
    row = conn.execute(
        "SELECT deleted_at FROM calendar_events WHERE id='ev-1'"
    ).fetchone()
    assert changed and row["deleted_at"] is not None and payload is None


def test_pull_payload_carries_google_fields(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    _apply_calendar_event(conn, _change(), 1)
    conn.execute(
        "UPDATE calendar_events SET google_event_id='g1', "
        "google_html_link='https://cal/x' WHERE id='ev-1'"
    )
    payload = _calendar_event_payload(
        conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    )
    assert payload["google_event_id"] == "g1"
    assert payload["google_html_link"] == "https://cal/x"
    assert payload["needs_date"] == 0
    assert payload["end"] == "2026-10-01T15:00:00"


def test_change_log_accepts_calendar_event_and_preserves_projection(tmp_path: Path) -> None:
    conn = _conn(tmp_path)
    _apply_calendar_event(conn, _change(), 1)
    row = conn.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    payload = _calendar_event_payload(row)
    seq = record_change(
        conn,
        entity_type="calendar_event",
        entity_id="ev-1",
        op="upsert",
        device_id="device-1",
        payload=payload,
        now=1,
    )
    logged = conn.execute(
        "SELECT entity_type, payload FROM change_log WHERE seq = ?", (seq,)
    ).fetchone()
    assert logged["entity_type"] == "calendar_event"
    assert json.loads(logged["payload"])["end"] == "2026-10-01T15:00:00"
