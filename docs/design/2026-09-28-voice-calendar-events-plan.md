# Voice → Google Calendar events + Meeting restore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development (server half → Ted via Bot Chat in its own worktree; client half in the main checkout). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A spoken "add this to my calendar …" in a recording creates a Google Calendar event on the user's primary calendar, visible as a small card with Undo on the recording; Meeting capture returns to the home picker and list create-menu.

**Architecture:** Mirror the To Do spine. Client parses the transcript → `calendar_events` row → device sync → server `_apply_calendar_event` → `google_calendar_worker` pushes/pulls on the existing 5-min Google tick with the existing OAuth link → Google ids/links flow back through `change_log`. Spec: `docs/design/2026-09-28-voice-calendar-events.md` — read it first; every rule below cites its section.

**Tech Stack:** Flutter 3.47.6 / drift (client DB v25 → v26), FastAPI + sqlite3 + `requests` (server), Google Calendar API v3.

## Global Constraints

- Scope string: `https://www.googleapis.com/auth/calendar.events.owned` appended to `OAUTH_SCOPE` (`server/app/api/google_tasks.py:28`).
- Entity type wire value: `calendar_event`. Table: `calendar_events`. Column named `end_` in SQL (`end` is a keyword), `end` in JSON payloads.
- Server-only columns (never in device push, preserved across upserts, present in pull): `google_event_id`, `google_html_link`, `google_updated`. Client-only: `capture_fingerprint`.
- `needs_date` events only when the dump's mode is `brain_dump` (spec C3). Meeting: skipped.
- Timed event = start + 60 min; `time_zone` IANA from the client.
- Many repo files are CRLF (Dart screens, AGENTS.md, CHANGELOG.md, README.md). Multi-line `patch` on them fails silently — use byte-level replace (read bytes, detect `\r\n`, `assert count == 1`, write).
- Gates: server `cd server && .venv-test/Scripts/python.exe -m pytest -q` (baseline 612 + Ted's path-guard additions); client `flutter analyze` + `timeout 300 flutter test` (baseline 2619 ~2 skipped). PATH exports: `/c/Users/Jeff/AppData/Local/flutter/bin`.
- Commit green work before sabotage. Every seam in the spec's "Sabotage seams" list gets a proof with quoted failure text.
- Never `dart run build_runner` without `--delete-conflicting-outputs`; commit `local_db.g.dart`.

---

## Half A — Server (Ted, worktree `.worktrees/calendar-server`, branch `feature/calendar-server` off main)

### Task A1: schema + migration + sync apply

**Files:**
- Modify: `server/app/db.py` (after the `todos` block ~L238; migrations list where `_migrate_dumps_meeting_notes` is registered)
- Modify: `server/app/models.py:221` (`entity_type` Literal)
- Modify: `server/app/api/sync.py` (`_apply_todo` L351 as the template; dispatch L603)
- Test: `server/tests/test_calendar_sync_apply.py`

**Interfaces:**
- Produces: table `calendar_events`, `CALENDAR_SERVER_ONLY_FIELDS = frozenset({"google_event_id","google_html_link","google_updated"})`, `_apply_calendar_event(conn, change, now) -> tuple[bool, dict|None]`, `_calendar_event_payload(row) -> dict` (pull shape, includes server-only fields, never `capture_fingerprint`).

- [ ] **Step 1: failing tests**

```python
# server/tests/test_calendar_sync_apply.py
from datetime import UTC, datetime
import sqlite3
import pytest
from app.api.sync import _apply_calendar_event, _calendar_event_payload
from app.db import init_db
from app.models import SyncChange

def _conn(tmp_path):
    c = sqlite3.connect(tmp_path / "t.sqlite"); c.row_factory = sqlite3.Row
    init_db(c); return c

def _change(op="upsert", **payload):
    base = {"id": "ev-1", "title": "Dentist", "start": "2026-10-01T14:00:00",
            "end": "2026-10-01T15:00:00", "all_day": 0, "time_zone": "America/New_York",
            "needs_date": 0, "source": "voice", "source_ref": "dump-1",
            "created_at": "2026-09-28T20:00:00+00:00", "updated_at": "2026-09-28T20:00:00+00:00",
            "capture_fingerprint": "should-not-be-stored"}
    base.update(payload)
    return SyncChange(entity_type="calendar_event", entity_id="ev-1", op=op,
                      payload=None if op == "delete" else base)

def test_upsert_stores_row_and_drops_client_only_field(tmp_path):
    c = _conn(tmp_path)
    changed, payload = _apply_calendar_event(c, _change(), 1)
    row = c.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert changed and row["title"] == "Dentist" and row["end_"] == "2026-10-01T15:00:00"
    assert "capture_fingerprint" not in row.keys()
    assert payload["end"] == "2026-10-01T15:00:00" and "capture_fingerprint" not in payload

def test_server_only_fields_preserved_across_device_upsert(tmp_path):
    c = _conn(tmp_path); _apply_calendar_event(c, _change(), 1)
    c.execute("UPDATE calendar_events SET google_event_id='g1', google_html_link='https://x', google_updated='2026-09-28T20:01:00Z' WHERE id='ev-1'")
    _apply_calendar_event(c, _change(title="Dentist (moved)", updated_at="2026-09-28T20:05:00+00:00",
                                     google_event_id="CLIENT-LIES"), 2)
    row = c.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert row["google_event_id"] == "g1" and row["title"] == "Dentist (moved)"

def test_stale_write_dropped(tmp_path):
    c = _conn(tmp_path); _apply_calendar_event(c, _change(updated_at="2026-09-28T21:00:00+00:00"), 1)
    changed, _ = _apply_calendar_event(c, _change(title="old", updated_at="2026-09-28T20:00:00+00:00"), 2)
    assert changed is False
    assert c.execute("SELECT title FROM calendar_events WHERE id='ev-1'").fetchone()[0] == "Dentist"

def test_delete_soft_deletes(tmp_path):
    c = _conn(tmp_path); _apply_calendar_event(c, _change(), 1)
    changed, payload = _apply_calendar_event(c, _change(op="delete"), 2)
    row = c.execute("SELECT deleted_at FROM calendar_events WHERE id='ev-1'").fetchone()
    assert changed and row["deleted_at"] is not None and payload is None

def test_pull_payload_carries_google_fields(tmp_path):
    c = _conn(tmp_path); _apply_calendar_event(c, _change(), 1)
    c.execute("UPDATE calendar_events SET google_event_id='g1', google_html_link='https://cal/x' WHERE id='ev-1'")
    p = _calendar_event_payload(c.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone())
    assert p["google_event_id"] == "g1" and p["google_html_link"] == "https://cal/x" and p["needs_date"] == 0
```

- [ ] **Step 2: run → fails** `pytest tests/test_calendar_sync_apply.py -q` → `ImportError: cannot import name '_apply_calendar_event'`.

- [ ] **Step 3: schema** in `db.py` after the todos index:

```sql
CREATE TABLE IF NOT EXISTS calendar_events (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    start TEXT NOT NULL,
    end_ TEXT NOT NULL,
    all_day INTEGER NOT NULL DEFAULT 1,
    time_zone TEXT NOT NULL,
    needs_date INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'voice',
    source_ref TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    -- server-authored Google bookkeeping; projected OUT of device pushes
    google_event_id TEXT,
    google_html_link TEXT,
    google_updated TEXT
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_updated_at ON calendar_events(updated_at DESC);
```
`CREATE TABLE IF NOT EXISTS` in the schema string is the existing pattern for new tables (see `google_list_cursor`); no ALTER migration needed. Also `ALTER TABLE google_tasks_link ADD COLUMN granted_scope TEXT` via a `_migrate_google_link_scope` guarded by `PRAGMA table_info` like `_migrate_jobs_request_id` (L288) — Task A3 uses it.

- [ ] **Step 4: models** — `entity_type: Literal["dump","notebook","note","folder","ink_index","todo","calendar_event"]`.

- [ ] **Step 5: apply** — copy `_apply_todo` (L351-~L470) to `_apply_calendar_event`: same LWW on `updated_at`, same delete branch; INSERT/UPDATE column list = spec columns MINUS the three server-only ones MINUS `capture_fingerprint` (never read from payload). Payload keys map `end` → column `end_`. Dispatch: add `elif change.entity_type == "calendar_event": changed, publish_payload = _apply_calendar_event(db, change, now)` mirroring the todo branch at L603. `_calendar_event_payload(row)` returns every column with `end_` renamed to `end`. Add the pull-side projection wherever `_todo_payload` is used for the feed (grep `entity_type == "todo"` in sync.py pull path and add the sibling).

- [ ] **Step 6: run → 5 pass; full suite green.** Commit: `feat(server): calendar_events entity — schema, sync apply, pull payload`.

### Task A2: Google Calendar worker — push / delete

**Files:**
- Create: `server/app/services/google_calendar_worker.py`
- Modify: `server/app/services/google_tasks_worker.py:969` (`run_cycle` calls the calendar cycle after the tasks push/pull, inside the same try so one status write covers both)
- Test: `server/tests/test_google_calendar_worker.py`

**Interfaces:**
- Consumes: `google_tasks_worker._request`, `_refresh_access_token`, `_now_rfc3339`, `record_change` (from `app.api.sync` — import the same way `_publish_todo` does).
- Produces: `event_to_google(row) -> dict`, `push_events(db, access_token) -> int`, `delete_events(db, access_token) -> int`, `run_calendar_cycle(db, access_token) -> CalendarStats(pushed, pulled, deleted)`.

- [ ] **Step 1: failing tests** — use `responses` if present in the venv (`grep responses server/pyproject.toml`), else monkeypatch `google_calendar_worker._request` with a recorder:

```python
# server/tests/test_google_calendar_worker.py
import sqlite3, pytest
from app.db import init_db
from app.services import google_calendar_worker as w

def _db(tmp_path):
    c = sqlite3.connect(tmp_path/"t.sqlite"); c.row_factory = sqlite3.Row; init_db(c); return c

def _seed(c, **kw):
    row = dict(id="ev-1", title="Dentist", start="2026-10-01T14:00:00", end_="2026-10-01T15:00:00",
               all_day=0, time_zone="America/New_York", needs_date=0, source="voice", source_ref="dump-1",
               created_at="2026-09-28T20:00:00+00:00", updated_at="2026-09-28T20:00:00+00:00")
    row.update(kw)
    c.execute(f"INSERT INTO calendar_events ({','.join(row)}) VALUES ({','.join('?'*len(row))})", tuple(row.values()))
    c.commit()

class Rec:
    def __init__(self, replies): self.calls=[]; self.replies=list(replies)
    def __call__(self, method, url, **kw):
        self.calls.append((method, url, kw.get("json")))
        class R:
            def __init__(s, body, code): s._b=body; s.status_code=code
            def json(s): return s._b
        body, code = self.replies.pop(0); return R(body, code)

def test_timed_event_body_has_datetime_and_timezone():
    body = w.event_to_google({"title":"Dentist","start":"2026-10-01T14:00:00","end_":"2026-10-01T15:00:00",
                              "all_day":0,"time_zone":"America/New_York","id":"ev-1","source_ref":"dump-1"})
    assert body["start"] == {"dateTime":"2026-10-01T14:00:00","timeZone":"America/New_York"}
    assert body["end"]["dateTime"] == "2026-10-01T15:00:00"
    assert body["extendedProperties"]["private"]["tangent_id"] == "ev-1"
    assert "tangent://dump/dump-1" in body["description"]

def test_all_day_event_body_uses_date_only():
    body = w.event_to_google({"title":"Trip","start":"2026-10-01","end_":"2026-10-02","all_day":1,
                              "time_zone":"America/New_York","id":"ev-2","source_ref":"dump-1"})
    assert body["start"] == {"date":"2026-10-01"} and body["end"] == {"date":"2026-10-02"}

def test_push_inserts_new_and_stores_ids(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c)
    rec = Rec([({"id":"g1","htmlLink":"https://cal/g1","updated":"2026-09-28T20:00:05.000Z"}, 200)])
    monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(c, "tok") == 1
    m, url, _ = rec.calls[0]; assert m == "POST" and url.endswith("/calendars/primary/events")
    row = c.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert (row["google_event_id"], row["google_html_link"]) == ("g1", "https://cal/g1")
    assert c.execute("SELECT count(*) FROM change_log WHERE entity_type='calendar_event'").fetchone()[0] == 1

def test_push_patches_changed_existing(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c, google_event_id="g1", google_updated="2026-09-28T19:00:00Z",
                              updated_at="2026-09-28T20:00:00+00:00")
    rec = Rec([({"id":"g1","htmlLink":"https://cal/g1","updated":"2026-09-28T20:00:05.000Z"}, 200)])
    monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(c, "tok") == 1
    assert rec.calls[0][0] == "PATCH" and rec.calls[0][1].endswith("/events/g1")

def test_push_skips_unchanged(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c, google_event_id="g1", google_updated="2026-09-28T21:00:00Z")
    rec = Rec([]); monkeypatch.setattr(w, "_request", rec)
    assert w.push_events(c, "tok") == 0 and rec.calls == []

def test_delete_removes_on_google_and_tolerates_gone(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c, google_event_id="g1", deleted_at="2026-09-28T22:00:00+00:00")
    _seed(c, id="ev-2", google_event_id="g2", deleted_at="2026-09-28T22:00:00+00:00")
    rec = Rec([({}, 204), ({"error":{"code":410}}, 410)]); monkeypatch.setattr(w, "_request", rec)
    assert w.delete_events(c, "tok") == 2
    assert [r[0] for r in rec.calls] == ["DELETE","DELETE"]
    assert c.execute("SELECT count(*) FROM calendar_events WHERE google_event_id IS NOT NULL").fetchone()[0] == 0
```

- [ ] **Step 2: run → fails** (`ModuleNotFoundError`).

- [ ] **Step 3: implement** `google_calendar_worker.py`:

```python
CAL_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
def _request(*a, **k): return google_tasks_worker._request(*a, **k)   # monkeypatch seam

def event_to_google(row) -> dict:
    when = ({"date": row["start"]}, {"date": row["end_"]}) if row["all_day"] else (
        {"dateTime": row["start"], "timeZone": row["time_zone"]},
        {"dateTime": row["end_"], "timeZone": row["time_zone"]})
    return {"summary": row["title"], "start": when[0], "end": when[1],
            "description": f"From Tangent recording\ntangent://dump/{row['source_ref']}",
            "extendedProperties": {"private": {"tangent_id": row["id"]}}}

def _publish(db, event_id, op="upsert"): ... # mirror _publish_todo with _calendar_event_payload

def push_events(db, access_token) -> int:
    rows = db.execute("""SELECT * FROM calendar_events WHERE deleted_at IS NULL
        AND (google_event_id IS NULL OR google_updated IS NULL OR updated_at > google_updated)""").fetchall()
    n = 0
    for row in rows:
        body = event_to_google(row)
        if row["google_event_id"]:
            r = _request("PATCH", f"{CAL_BASE}/{row['google_event_id']}", access_token=access_token, json=body)
        else:
            r = _request("POST", CAL_BASE, access_token=access_token, json=body)
        g = r.json()
        db.execute("UPDATE calendar_events SET google_event_id=?, google_html_link=?, google_updated=? WHERE id=?",
                   (g["id"], g.get("htmlLink"), g.get("updated"), row["id"]))
        _publish(db, row["id"]); n += 1
    db.commit(); return n

def delete_events(db, access_token) -> int:
    rows = db.execute("SELECT id, google_event_id FROM calendar_events WHERE deleted_at IS NOT NULL AND google_event_id IS NOT NULL").fetchall()
    for row in rows:
        _request("DELETE", f"{CAL_BASE}/{row['google_event_id']}", access_token=access_token, expected=(204, 404, 410))
        db.execute("UPDATE calendar_events SET google_event_id=NULL WHERE id=?", (row["id"],))
    db.commit(); return len(rows)
```
`updated_at > google_updated` compares ISO strings with different offsets (`+00:00` vs `Z`) — normalise both through `google_tasks_worker._parse_instant` in Python rather than in SQL (select candidates, filter in a loop).

- [ ] **Step 4: run → 6 pass.** Commit: `feat(server): google_calendar_worker push + delete`.

### Task A3: pull, scope gate, cycle wiring, status

**Files:**
- Modify: `server/app/services/google_calendar_worker.py`
- Modify: `server/app/services/google_tasks_worker.py:969-1030` (`run_cycle`), `:102` (`exchange_code` result → `granted_scope`)
- Modify: `server/app/api/google_tasks.py:28` (scope), `:280-300` (store `granted_scope` from `tokens["scope"]`), `_status` L99 (add `calendar` block)
- Modify: `server/app/models.py` `GoogleTasksStatus` (+ `calendar: CalendarStatus`)
- Modify: `server/app/db.py` `google_tasks_link` migration for `granted_scope`, new `google_calendar_cursor` single-row table or a column `calendar_updated_min TEXT` on the link row (pick the column — one calendar).
- Test: extend `server/tests/test_google_calendar_worker.py`, `server/tests/test_google_tasks_api.py` (whichever file covers `/v1/google/status` today — grep `reauth_required` in tests)

**Interfaces:**
- Produces: `pull_events(db, access_token) -> int`, `has_calendar_scope(row) -> bool`, `CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events.owned"`, status JSON `calendar: {"enabled": bool, "last_pushed": int, "last_pulled": int, "last_error": str|None}`.

- [ ] **Step 1: failing tests**

```python
def test_pull_applies_google_newer_and_clears_needs_date(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c, google_event_id="g1", google_updated="2026-09-28T20:00:00Z",
                              start="2026-09-28", end_="2026-09-29", all_day=1, needs_date=1)
    rec = Rec([({"items":[{"id":"g1","status":"confirmed","summary":"Dentist","updated":"2026-09-28T21:00:00.000Z",
                            "start":{"date":"2026-10-02"},"end":{"date":"2026-10-03"},
                            "extendedProperties":{"private":{"tangent_id":"ev-1"}}}],
                 "nextSyncToken":"tok-1"}, 200)])
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(c, "tok") == 1
    row = c.execute("SELECT * FROM calendar_events WHERE id='ev-1'").fetchone()
    assert (row["start"], row["needs_date"]) == ("2026-10-02", 0)
    assert c.execute("SELECT calendar_sync_token FROM google_tasks_link").fetchone()[0] == "tok-1"

def test_pull_ignores_foreign_events(tmp_path, monkeypatch):
    c = _db(tmp_path)
    rec = Rec([({"items":[{"id":"zz","status":"confirmed","summary":"Not ours","updated":"2026-09-28T21:00:00.000Z",
                            "start":{"date":"2026-10-02"},"end":{"date":"2026-10-03"}}], "nextSyncToken":"t"}, 200)])
    monkeypatch.setattr(w, "_request", rec)
    assert w.pull_events(c, "tok") == 0
    assert c.execute("SELECT count(*) FROM calendar_events").fetchone()[0] == 0

def test_pull_cancelled_soft_deletes(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c, google_event_id="g1", google_updated="2026-09-28T20:00:00Z")
    rec = Rec([({"items":[{"id":"g1","status":"cancelled","updated":"2026-09-28T21:00:00.000Z",
                            "extendedProperties":{"private":{"tangent_id":"ev-1"}}}], "nextSyncToken":"t"}, 200)])
    monkeypatch.setattr(w, "_request", rec)
    w.pull_events(c, "tok")
    assert c.execute("SELECT deleted_at FROM calendar_events WHERE id='ev-1'").fetchone()[0] is not None

def test_scope_gate_marks_reauth_and_skips_calendar(tmp_path, monkeypatch):
    c = _db(tmp_path); _seed(c)
    c.execute("UPDATE google_tasks_link SET status='connected', granted_scope='https://www.googleapis.com/auth/tasks openid email' WHERE id=1")
    rec = Rec([]); monkeypatch.setattr(w, "_request", rec)
    stats = w.run_calendar_cycle(c, "tok")
    assert rec.calls == [] and stats.pushed == 0
    row = c.execute("SELECT status, last_error FROM google_tasks_link").fetchone()
    assert row["status"] == "reauth_required" and "Calendar permission" in row["last_error"]
```
Use `syncToken` (Calendar's incremental sync) rather than `updatedMin` — store it as `calendar_sync_token` on the link row; a 410 on list means the token expired → clear it and do one full list with `showDeleted=true`. Pull uses `GET ...?syncToken=...&showDeleted=true` (first run: `?showDeleted=true&maxResults=250&privateExtendedProperty=` is NOT usable across ids; filter on `extendedProperties.private.tangent_id` in Python).

- [ ] **Step 2: run → fails.** **Step 3: implement** per the spec's worker section (pull → LWW: Google `updated` > row `google_updated` wins → write title/start/end/all_day, `needs_date=0` when the date changed, `google_updated`; `cancelled` → `deleted_at=now`; `_publish` each). `run_calendar_cycle`: read link row; if `not has_calendar_scope(row)` → `UPDATE google_tasks_link SET status='reauth_required', last_error='Google Calendar permission not granted — Reconnect'` and return zeros; else delete → push → pull. Wire into `run_cycle` after `_pull_all`, stats added to the status write (`last_cal_pushed`, `last_cal_pulled` columns or reuse `last_error`). `exchange_code` callers store `tokens.get("scope")` into `granted_scope`. `OAUTH_SCOPE` += ` https://www.googleapis.com/auth/calendar.events.owned`. `_status` emits the `calendar` block; `has_calendar_scope` = `CALENDAR_SCOPE in (row["granted_scope"] or "").split()`.

- [ ] **Step 4: run → green; full suite green.** Commit: `feat(server): calendar pull with syncToken, scope gate → reauth_required, status block`.

- [ ] **Step 5: sabotage** (commit first): (a) delete the `has_calendar_scope` check → `test_scope_gate…` must fail with `rec.calls == []` broken; (b) drop `"timeZone"` from `event_to_google` → `test_timed_event_body…` fails on the dict equality; (c) drop the `needs_date=0` write on pull → `test_pull_applies…` fails `(row["start"], row["needs_date"]) == ("2026-10-02", 0)`. Quote each. Restore, green, report.

---

## Half B — Client (main checkout, branch `feature/calendar-client` off main)

### Task B0: Meeting capture restored (spec C4) — lands FIRST, own commit, can ship alone

**Files:**
- Modify: `client/lib/screens/home/home_screen.dart`, `client/lib/screens/dump/dumps_list_screen.dart` (revert the UI hunks of `b607a93`: `git show b607a93 -- client/lib/screens/home/home_screen.dart client/lib/screens/dump/dumps_list_screen.dart`)
- Test: `client/test/widget/dumps_list_fab_test.dart`, `client/test/widget/home_dumps_fab_result_test.dart` (restore their Meeting cases from `git show b607a93^:client/test/widget/...`)

- [ ] **Step 1:** `git show b607a93^:client/test/widget/home_dumps_fab_result_test.dart > /tmp/x` — diff against current; bring back the `DumpMode.meeting` picker case and the create-menu `meeting` action test. Run → RED (segment missing).
- [ ] **Step 2:** Restore the picker segment + description line and `DumpsCreateAction.meeting` + menu entry by reverse-applying only those hunks (`git diff b607a93 b607a93^ -- <two screen files> | git apply --3way --include='client/lib/screens/*'`); keep every rename ("Recordings") intact — `recordings_rename_test.dart` must stay green.
- [ ] **Step 3:** analyze + full suite green. Commit: `feat(client): Meeting capture back in the home picker and list create menu (C4)`.

### Task B1: shared date grammar + `CalendarVoiceParser`

**Files:**
- Create: `client/lib/services/voice_date_grammar.dart` (moved regexes + `resolveDatePhrase(match, recordedOn) -> String?` extracted from `TodoVoiceParser`), `client/lib/services/calendar_voice_parser.dart`
- Modify: `client/lib/services/todo_voice_parser.dart` (import the grammar; behaviour unchanged)
- Test: `client/test/unit/services/calendar_voice_parser_test.dart`; existing `todo_voice_parser*_test.dart` files are the golden — they must pass untouched.

**Interfaces:**
- Produces:
```dart
class VoiceCalendarEvent { final String title; final String start; final String end; final bool allDay; final bool needsDate; }
class CalendarVoiceParser {
  static List<VoiceCalendarEvent> parse(String? transcript, {required DateTime recordedOn, required DumpMode mode});
}
/// exposed from voice_date_grammar.dart
class ParsedTime { final int hour, minute; }
ParsedTime? parseTimePhrase(String s);      // "at 3", "3:30 pm", "noon", "at 15:00", "3 o'clock" → value; null otherwise
```

- [ ] **Step 1: failing tests** (recordedOn = `DateTime(2026, 9, 28, 20)` Monday):

```dart
group('CalendarVoiceParser', () {
  final DateTime on = DateTime(2026, 9, 28, 20);
  List<VoiceCalendarEvent> p(String t, {DumpMode mode = DumpMode.brainDump}) =>
      CalendarVoiceParser.parse(t, recordedOn: on, mode: mode);

  test('date + time → timed one-hour event, title stripped of the phrase', () {
    final e = p('so anyway add the dentist Thursday at two to my calendar').single;
    expect(e.title, 'The dentist');
    expect(e.start, '2026-10-01T14:00:00'); expect(e.end, '2026-10-01T15:00:00');
    expect(e.allDay, isFalse); expect(e.needsDate, isFalse);
  });
  test('date only → all-day', () {
    final e = p('put the car inspection on my calendar for October 15th').single;
    expect(e.start, '2026-10-15'); expect(e.end, '2026-10-16'); expect(e.allDay, isTrue);
  });
  test('no date, brain dump → today all-day, flagged', () {
    final e = p('add this to my calendar renew the passport').single;
    expect(e.start, '2026-09-28'); expect(e.needsDate, isTrue); expect(e.title, 'Renew the passport');
  });
  test('time only, brain dump → today at that time, flagged', () {
    final e = p('calendar this dentist at 2').single;
    expect(e.start, '2026-09-28T14:00:00'); expect(e.needsDate, isTrue);
  });
  test('no date, MEETING → skipped', () {
    expect(p('we should put that on the calendar', mode: DumpMode.meeting), isEmpty);
  });
  test('dated, MEETING → still created', () {
    expect(p('add to my calendar sprint review Friday at 10', mode: DumpMode.meeting).single.start, '2026-10-02T10:00:00');
  });
  test('two triggers → two events, spans split at the next trigger', () {
    final es = p('add to my calendar dentist Thursday at two and also put this on my calendar oil change Saturday');
    expect(es.map((e) => e.title), ['Dentist', 'Oil change']);
  });
  test('no trigger → nothing; empty title after stripping → nothing', () {
    expect(p('remind me to call mom tomorrow'), isEmpty);
    expect(p('add this to my calendar tomorrow'), isEmpty);
  });
});
group('parseTimePhrase', () {
  test('bare hours: 1-7 pm, 8-11 am, 12 pm', () {
    expect(parseTimePhrase('at 3')!.hour, 15); expect(parseTimePhrase('at 9')!.hour, 9); expect(parseTimePhrase('at 12')!.hour, 12);
  });
  test('explicit meridiem, minutes, noon/midnight, 24h, o clock', () {
    expect(parseTimePhrase('3:30 am')!.minute, 30); expect(parseTimePhrase('noon')!.hour, 12);
    expect(parseTimePhrase('midnight')!.hour, 0); expect(parseTimePhrase('at 15:00')!.hour, 15);
    expect(parseTimePhrase("3 o'clock")!.hour, 15);
  });
  test('in the morning forces am', () => expect(parseTimePhrase('at 7 in the morning')!.hour, 7));
});
```
- [ ] **Step 2: run → fails** (no such file). **Step 3:** extract grammar; implement parser: trigger regex per spec, split transcript at trigger positions, per span strip date/time via the shared removal, `parseTimePhrase` on the `tb`/`ta` groups, build shapes per the spec table, apply the mode gate, title = sentence-case trimmed span, `≤200` chars. **Step 4:** run new + ALL `todo_voice_parser*` tests → green. Commit: `feat(client): CalendarVoiceParser on the shared voice date grammar (time values parsed for the first time)`.

- [ ] **Step 5: sabotage** — swap the mode gate to `mode != DumpMode.meeting` inverted → 'no date, MEETING → skipped' must fail with `Expected: empty  Actual: [VoiceCalendarEvent…]`. Restore.

### Task B2: `CalendarEvents` drift table (v26) + repository + sync

**Files:**
- Modify: `client/lib/data/local_db.dart` (`class Todos extends Table` L334 as template; `schemaVersion => 26` L407; migration block ~L896), regenerate `local_db.g.dart`
- Create: `client/lib/data/calendar_event_repository.dart` (mirror `todo_repository.dart:19`: `insertAll`, `eventsFromSource(dumpId)`, `watchEventsFromSource(dumpId)`, `softDeleteFromSource(dumpId)`, `applyRemote(payload)`)
- Modify: `client/lib/services/document_sync_engine.dart` (`'todo'` branches at L235 push-queue, L776 push payload, L857 pull apply → add `'calendar_event'` siblings; push payload EXCLUDES `captureFingerprint`, `googleEventId`, `googleHtmlLink`, `googleUpdated`; pull WRITES the three google fields + `needsDate`)
- Test: `client/test/unit/data/calendar_event_repository_test.dart`, add `userVersion, 26` bumps to `local_db_test.dart:234,348` and every other `userVersion, 25)` / `schemaVersion, 25)` site (grep), `client/test/unit/services/calendar_event_sync_test.dart` (copy the scripted-client shape of `dump_sync_test.dart`)

- [ ] **Step 1:** `grep -rn "userVersion, 25)\|schemaVersion, 25)" client/test` → bump all to 26 → RED. Write repository tests (insert two, watch emits, soft-delete hides, applyRemote preserves local `captureFingerprint` while writing google fields) and a sync test: push payload for a local event lacks the four excluded keys; pull with `google_html_link` lands on the row.
- [ ] **Step 2:** table (`TextColumn get end` named `end_` via `@JsonKey`/`named('end_')`), `schemaVersion => 26`, `m.createTable(calendarEvents)` in `onUpgrade` for `from < 26`; `dart run build_runner build --delete-conflicting-outputs`; repository; sync branches.
- [ ] **Step 3:** green; full suite green. Commit: `feat(client): calendar_events table (v26), repository, sync push/pull with server-only projection`.
- [ ] **Step 4: sabotage** — include `captureFingerprint` in the push payload → sync test fails `Expected: not contains 'capture_fingerprint'`. Restore.

### Task B3: capture seam + idempotency

**Files:**
- Create: `client/lib/services/calendar_voice_capture.dart` (`captureVoiceEvents({db, dumpId, transcript, recordedOn, mode, repository?}) -> Future<List<CalendarEventRow>>`, `captureVoiceEventsQuietly(...)`) — copy `todo_voice_capture.dart:38-140` structure incl. `captureFingerprintOf`
- Modify: `client/lib/services/server_transcription_service.dart:758,1134`, `client/lib/services/document_sync_engine.dart:403` — add the sibling call right after each `captureVoiceTodosQuietly` (the dump row is already in hand there; pass `mode: dump.mode`)
- Test: `client/test/unit/services/calendar_voice_capture_test.dart`

- [ ] **Step 1: tests** — first capture inserts N rows with fingerprint; same transcript again → no new rows; changed transcript adds only the new title; after `softDeleteFromSource` a re-run does NOT resurrect; `mode: meeting` + no-date → nothing inserted; `transcript: null` → nothing.
- [ ] **Step 2:** implement; wire the three call sites. **Step 3:** green + full suite. Commit: `feat(client): capture calendar events from transcripts at the same seams as To Do (idempotent, mode-gated)`.
- [ ] **Step 4: sabotage** — drop the fingerprint comparison → 'same transcript again' fails with `Expected: 1  Actual: 2`. Restore.

### Task B4: `VoiceEventsCard` + Settings line

**Files:**
- Create: `client/lib/widgets/voice_events_card.dart` (copy `voice_todos_card.dart` structure; provider `voiceEventsForDumpProvider`)
- Modify: `client/lib/screens/dump/dump_detail_screen.dart` (render directly below `VoiceTodosCard` — find `VoiceTodosCard(dumpId:` and add the sibling; CRLF file → byte-level edit)
- Modify: `client/lib/screens/settings/google_tasks_section.dart` (one line from `status.calendar`: "Calendar: connected · N events" / the `reauth_required` banner text already covers the scope case)
- Modify: client `GoogleTasksStatus` model + its `fromJson` for the `calendar` block
- Test: `client/test/widget/voice_events_card_test.dart`, extend `dump_detail_*` widget test that pins the To Do card to also pin this one, `google_tasks_section_test.dart` for the line
- Dependency: `url_launcher` — check `pubspec.yaml`; if absent, add `^6.3.0` (pub.dev status check + Kotlin floor per skill), and `launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication)`.

- [ ] **Step 1: tests** — no rows → `SizedBox.shrink` (key absent); row without link → text ends with '· syncing…' and tap is a no-op (`launcher` fake records zero calls); row with link → tap calls launcher with that URL; flagged row → contains 'no date said' and 'tap to fix'; timed row formats `Thu Oct 1, 2:00 PM`, all-day `Thu Oct 1`; Undo → `softDeleteFromSource(dumpId)` called and the card disappears on the next stream emit.
- [ ] **Step 2:** implement with an injectable `UrlLauncher` seam (`typedef OpenExternal = Future<bool> Function(Uri)`; provider default = `launchUrl`). Keys per spec. **Step 3:** green + full suite. Commit: `feat(client): 'Added to your calendar' card with Undo + Google link; Settings calendar line`.
- [ ] **Step 4: sabotage** — make tap ignore the missing-link guard → 'row without link tap is a no-op' fails `Expected: 0 calls  Actual: 1`. Restore.

---

## Merge, release, proof

- [ ] Merge `feature/calendar-server` then `feature/calendar-client` `--no-ff` into main; both full gates on merged main; one extra sabotage nobody proved: server `_apply_calendar_event` accepting `google_event_id` from a device payload (test A1 #2 covers — mutate the projection and quote).
- [ ] Rebuild the server container (`docker compose -f C:/Users/Jeff/Documents/ADH2/server/docker-compose.yml up -d --build`); check `/v1/google/status` shows `calendar.enabled=false` + `reauth_required` with the scope message; Jeff taps **Reconnect** → `granted_scope` contains `calendar.events.owned`.
- [ ] Version bump (7 sites, `chore(release): v1.35.0`), CHANGELOG, README feature row + pairing/Google section (mention Calendar API enable + `calendar.events.owned`), AGENTS.md Status paragraph (CRLF!), `docs/design` spec status line.
- [ ] Device proof per spec ("Device proof before tagging") on the Fold, real data, before tagging. Tag, three assets, Discord ping.
