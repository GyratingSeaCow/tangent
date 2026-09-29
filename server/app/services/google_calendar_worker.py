# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Calendar REST synchronization for Tangent calendar events."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

from app.api.sync import _calendar_event_payload
from app.services import google_tasks_worker
from app.services.change_log import record_change

CAL_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"


@dataclass
class CalendarStats:
    pushed: int = 0
    pulled: int = 0
    deleted: int = 0


def _request(*args: Any, **kwargs: Any):
    """Delegating seam so calendar HTTP can be tested independently."""
    return google_tasks_worker._request(*args, **kwargs)


def event_to_google(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
    """Map a local event to Google Calendar's writable representation."""
    if row["all_day"]:
        start = {"date": row["start"]}
        end = {"date": row["end_"]}
    else:
        start = {"dateTime": row["start"], "timeZone": row["time_zone"]}
        end = {"dateTime": row["end_"], "timeZone": row["time_zone"]}
    return {
        "summary": row["title"],
        "start": start,
        "end": end,
        "description": (
            f"From Tangent recording: {row['title']}\n"
            f"tangent://dump/{row['source_ref']}"
        ),
        "extendedProperties": {"private": {"tangent_id": row["id"]}},
    }


def _publish(db: sqlite3.Connection, event_id: str, *, op: str = "upsert") -> None:
    payload = None
    if op == "upsert":
        row = db.execute(
            "SELECT * FROM calendar_events WHERE id = ?", (event_id,)
        ).fetchone()
        if row is None:
            return
        payload = _calendar_event_payload(row)
    record_change(
        db,
        entity_type="calendar_event",
        entity_id=event_id,
        op=op,
        device_id="server",
        payload=payload,
    )


def push_events(db: sqlite3.Connection, access_token: str) -> int:
    """Insert or patch locally-newer live events and publish Google metadata."""
    rows = db.execute(
        "SELECT * FROM calendar_events WHERE deleted_at IS NULL ORDER BY id"
    ).fetchall()
    pushed = 0
    for row in rows:
        event_id = row["google_event_id"]
        needs_push = not event_id or not row["google_updated"]
        if event_id and row["google_updated"]:
            needs_push = google_tasks_worker._parse_instant(
                row["updated_at"]
            ) > google_tasks_worker._parse_instant(row["google_updated"])
        if not needs_push:
            continue
        if event_id:
            response = _request(
                "PATCH",
                f"{CAL_BASE}/{quote(str(event_id), safe='')}",
                access_token=access_token,
                json=event_to_google(row),
            )
        else:
            response = _request(
                "POST",
                CAL_BASE,
                access_token=access_token,
                expected=(200, 201),
                json=event_to_google(row),
            )
        event = google_tasks_worker._json_object(response)
        returned_id = event.get("id") or event_id
        updated = event.get("updated")
        if not returned_id or not updated:
            raise google_tasks_worker.GoogleTasksError(
                "Google Calendar write response omitted id or updated"
            )
        db.execute(
            "UPDATE calendar_events SET google_event_id = ?, "
            "google_html_link = ?, google_updated = ? WHERE id = ?",
            (
                str(returned_id),
                str(event["htmlLink"]) if event.get("htmlLink") else None,
                str(updated),
                row["id"],
            ),
        )
        _publish(db, row["id"])
        pushed += 1
    db.commit()
    return pushed


def delete_events(db: sqlite3.Connection, access_token: str) -> int:
    """Delete local tombstones in Google; 404/410 mean deletion is complete."""
    rows = db.execute(
        "SELECT id, google_event_id FROM calendar_events "
        "WHERE deleted_at IS NOT NULL AND google_event_id IS NOT NULL ORDER BY id"
    ).fetchall()
    for row in rows:
        _request(
            "DELETE",
            f"{CAL_BASE}/{quote(str(row['google_event_id']), safe='')}",
            access_token=access_token,
            expected=(204, 404, 410),
        )
        db.execute(
            "UPDATE calendar_events SET google_event_id = NULL WHERE id = ?",
            (row["id"],),
        )
    db.commit()
    return len(rows)


def run_calendar_cycle(
    db: sqlite3.Connection, access_token: str
) -> CalendarStats:
    """Run the Calendar half-cycle; pull is added with the incremental cursor."""
    stats = CalendarStats()
    stats.deleted = delete_events(db, access_token)
    stats.pushed = push_events(db, access_token)
    return stats
