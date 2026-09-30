# SPDX-License-Identifier: AGPL-3.0-or-later
"""Google Calendar REST synchronization for Tangent calendar events."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from urllib.parse import quote

from app.api.sync import _calendar_event_payload
from app.services import google_tasks_worker
from app.services.change_log import record_change

CAL_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events.owned"
CALENDAR_PERMISSION_ERROR = "Google Calendar permission not granted — Reconnect"


@dataclass
class CalendarStats:
    pushed: int = 0
    pulled: int = 0
    deleted: int = 0


def _request(*args: Any, **kwargs: Any):
    """Delegating seam so calendar HTTP can be tested independently."""
    return google_tasks_worker._request(*args, **kwargs)


# Legacy clients (Linux builds before the flutter_timezone fallback fix)
# stored OS abbreviations instead of IANA names; Google rejects those with
# 400 "Invalid time zone definition". Map the common US/UTC ones and fall
# back to UTC for anything else that isn't an Area/City name.
_TZ_ABBREVIATIONS = {
    "EST": "America/New_York", "EDT": "America/New_York",
    "CST": "America/Chicago", "CDT": "America/Chicago",
    "MST": "America/Denver", "MDT": "America/Denver",
    "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
    "UTC": "UTC", "GMT": "UTC", "Z": "UTC",
}


def _sanitize_time_zone(zone: str) -> str:
    if "/" in zone:
        return zone
    return _TZ_ABBREVIATIONS.get(zone.upper(), "UTC")


def event_to_google(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
    """Map a local event to Google Calendar's writable representation."""
    if row["all_day"]:
        start = {"date": row["start"]}
        end = {"date": row["end_"]}
    else:
        zone = _sanitize_time_zone(row["time_zone"])
        start = {"dateTime": row["start"], "timeZone": zone}
        end = {"dateTime": row["end_"], "timeZone": zone}
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


def has_calendar_scope(row: sqlite3.Row | dict[str, Any] | None) -> bool:
    if row is None:
        return False
    granted = row["granted_scope"] or ""
    return CALENDAR_SCOPE in str(granted).split()


def _local_datetime(value: object) -> str | None:
    """Return Calendar dateTime as the local wall-clock shape stored by Tangent."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.replace(tzinfo=None).isoformat(timespec="seconds")


def _apply_google_event(db: sqlite3.Connection, event: dict[str, Any]) -> bool:
    private = (event.get("extendedProperties") or {}).get("private") or {}
    tangent_id = private.get("tangent_id") if isinstance(private, dict) else None
    updated = event.get("updated")
    if not isinstance(tangent_id, str) or not isinstance(updated, str):
        return False
    existing = db.execute(
        "SELECT * FROM calendar_events WHERE id = ?", (tangent_id,)
    ).fetchone()
    if existing is None:
        return False
    google_instant = google_tasks_worker._parse_instant(updated)
    if existing["google_updated"] and google_instant <= google_tasks_worker._parse_instant(
        existing["google_updated"]
    ):
        return False

    google_id = str(event.get("id") or existing["google_event_id"] or "") or None
    html_link = event.get("htmlLink")
    if event.get("status") == "cancelled":
        db.execute(
            "UPDATE calendar_events SET deleted_at = ?, updated_at = ?, "
            "google_event_id = ?, google_html_link = COALESCE(?, google_html_link), "
            "google_updated = ? WHERE id = ?",
            (updated, updated, google_id, html_link, updated, tangent_id),
        )
        _publish(db, tangent_id, op="delete")
        return True

    raw_start = event.get("start")
    raw_end = event.get("end")
    if not isinstance(raw_start, dict) or not isinstance(raw_end, dict):
        return False
    all_day = "date" in raw_start and "date" in raw_end
    if all_day:
        start = raw_start.get("date")
        end = raw_end.get("date")
    else:
        start = _local_datetime(raw_start.get("dateTime"))
        end = _local_datetime(raw_end.get("dateTime"))
    if not isinstance(start, str) or not isinstance(end, str):
        return False
    date_changed = start != existing["start"] or end != existing["end_"]
    needs_date = 0 if existing["needs_date"] and date_changed else existing["needs_date"]
    time_zone = raw_start.get("timeZone") or existing["time_zone"]
    title = str(event.get("summary") or existing["title"])
    db.execute(
        """
        UPDATE calendar_events SET title = ?, start = ?, end_ = ?, all_day = ?,
            time_zone = ?, needs_date = ?, updated_at = ?, deleted_at = NULL,
            google_event_id = ?, google_html_link = COALESCE(?, google_html_link),
            google_updated = ?
        WHERE id = ?
        """,
        (
            title, start, end, int(all_day), time_zone, needs_date, updated,
            google_id, html_link, updated, tangent_id,
        ),
    )
    _publish(db, tangent_id)
    return True


def _calendar_pages(
    access_token: str, sync_token: str | None
) -> tuple[list[dict[str, Any]], str | None, bool]:
    """Fetch one incremental listing. The bool reports an expired sync token."""
    items: list[dict[str, Any]] = []
    page_token: str | None = None
    next_sync_token: str | None = sync_token
    while True:
        params: dict[str, Any] = {"showDeleted": "true", "maxResults": 250}
        if sync_token:
            params["syncToken"] = sync_token
        if page_token:
            params["pageToken"] = page_token
        response = _request(
            "GET",
            CAL_BASE,
            access_token=access_token,
            params=params,
            expected=(200, 410),
        )
        if response.status_code == 410:
            return [], None, True
        body = google_tasks_worker._json_object(response)
        items.extend(item for item in body.get("items") or [] if isinstance(item, dict))
        raw_page = body.get("nextPageToken")
        page_token = str(raw_page) if raw_page else None
        if not page_token:
            raw_sync = body.get("nextSyncToken")
            if raw_sync:
                next_sync_token = str(raw_sync)
            break
    return items, next_sync_token, False


def pull_events(db: sqlite3.Connection, access_token: str) -> int:
    """Apply Google-newer Tangent-owned events and advance Calendar syncToken."""
    db.execute(
        "INSERT OR IGNORE INTO google_tasks_link (id, status) "
        "VALUES (1, 'disconnected')"
    )
    row = db.execute(
        "SELECT calendar_sync_token FROM google_tasks_link WHERE id = 1"
    ).fetchone()
    sync_token = row["calendar_sync_token"] if row else None
    items, next_sync_token, expired = _calendar_pages(access_token, sync_token)
    if expired:
        db.execute(
            "UPDATE google_tasks_link SET calendar_sync_token = NULL WHERE id = 1"
        )
        items, next_sync_token, expired = _calendar_pages(access_token, None)
        if expired:  # Defensive: a full listing cannot legitimately return 410.
            raise google_tasks_worker.GoogleTasksError(
                "Google Calendar full sync token reset failed", status_code=410
            )
    pulled = sum(1 for event in items if _apply_google_event(db, event))
    db.execute(
        "UPDATE google_tasks_link SET calendar_sync_token = ? WHERE id = 1",
        (next_sync_token,),
    )
    db.commit()
    return pulled


def run_calendar_cycle(
    db: sqlite3.Connection, access_token: str
) -> CalendarStats:
    """Run delete, push, then pull after enforcing the exact Calendar scope."""
    row = db.execute("SELECT * FROM google_tasks_link WHERE id = 1").fetchone()
    if not has_calendar_scope(row):
        db.execute(
            "UPDATE google_tasks_link SET status = 'reauth_required', "
            "last_error = ?, last_cal_error = ? WHERE id = 1",
            (CALENDAR_PERMISSION_ERROR, CALENDAR_PERMISSION_ERROR),
        )
        db.commit()
        return CalendarStats()
    stats = CalendarStats()
    stats.deleted = delete_events(db, access_token)
    stats.pushed = push_events(db, access_token)
    stats.pulled = pull_events(db, access_token)
    return stats
