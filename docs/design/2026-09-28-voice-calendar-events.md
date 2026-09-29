# Voice → Google Calendar events + Meeting capture restored

Date: 2026-09-28 · Status: approved (Jeff's picks recorded below)
Builds on: `2026-09-27-todo-voice-capture.md` (trigger-phrase capture with a
visible card + Undo), `2026-09-27-voice-todo-relative-dates.md` (date
grammar), `2026-09-27-google-tasks-sync.md` (OAuth link, worker, LWW),
`2026-09-27-recordings-rename-meeting-removal.md` (what M1 removed).

## Decisions (Jeff, 2026-09-28)

- **C1 — Same shape as To Do capture.** A spoken trigger ("add this to my
  calendar") creates a Google Calendar event. Google Calendar is where the
  event is viewed and edited; Tangent shows only a small card on the
  recording, like the "Added to your To Do list" card, with Undo.
- **C2 — Approach A: mirror the To Do spine.** New `calendar_events`
  entity, client-side parser, local row, device sync, server worker pushes
  to Google, Google ids sync back. Rejected: server-side parsing (a second
  date parser in Python, no offline capture) and riding on `todos` (an
  event is not a to-do; the Tasks worker would grow `kind` branches).
- **C3 — No-date rule depends on the recording MODE.**
  - Brain Dump: a trigger with no date creates an all-day event on the
    recording's day, flagged `needs_date`; the card row reads
    "today (no date said) — tap to fix" and opens the event in Google
    Calendar. Created immediately (next worker cycle), not held: a
    misplaced visible event beats an invisible held one.
  - Meeting: a trigger with no date is **skipped** — people say "put that
    on the calendar" conversationally in meetings.
  - A time with no date ("add dentist at 2 to my calendar") is treated
    exactly like no date: today at 2:00, flagged (Brain Dump only).
- **C4 — Meeting capture comes back.** The home picker regains its
  Meeting segment and the recordings list its create-menu action (undo of
  v1.22.0 M1's UI removal only — `DumpMode.meeting`, the wire value and
  `MeetingNotesProcessor` never left). Own commit, lands first: the C3
  rule needs the mode to be a real choice again.
- **C5 — Scope.** `https://www.googleapis.com/auth/calendar.events.owned`
  (enabled by Jeff in the Cloud Console 2026-09-28). Added to the server's
  `OAUTH_SCOPE`; the existing Google Tasks link is reused. A stored token
  that lacks the calendar scope → `reauth_required` → the existing
  Reconnect banner. One connect covers both products.

## Trigger family (V-rules, mirroring the To Do parser)

Case-insensitive, optional trailing colon, tolerate "the calendar" / "my
calendar" / "my google calendar":

- `add (this|that|it) to (my|the) (google )?calendar`
- `put (this|that|it) on (my|the) (google )?calendar`
- `add to (my|the) (google )?calendar`
- `calendar (this|that)`

Capture span: everything after the trigger to the END of the transcript
(V1 rule). **One event per trigger**, not comma-split — "dentist and then
groceries" is one title; events are not list items. Multiple triggers in a
transcript → multiple events, each spanning to the next trigger or the end.

Title = the captured span with the date/time phrase removed (same
`_itemEndDate` / `_itemStartDate` removal as To Do), trimmed, sentence-cased,
max 200 chars. Empty title after removal → no event.

## Date + time grammar

Dates: the To Do grammar unchanged (absolute, relative, weekday, ordinal,
"a week from…", end-of-day family). Shared code — the date matcher moves
from `TodoVoiceParser` into `voice_date_grammar.dart` and both parsers
import it; To Do output stays byte-identical (golden test).

Time (new, value-parsed for the first time): the existing `_time` regex
gains a value:

| spoken | value |
|---|---|
| `at 3`, `at 3 pm`, `3pm`, `at 3 o'clock` | 15:00 (bare 1–7 → PM, 8–11 → AM, 12 → PM — a "morning"/"am" word overrides) |
| `at 3:30` | 15:30 |
| `noon` / `midnight` | 12:00 / 00:00 |
| `at 15:00` | 15:00 |
| `in the morning` after a time | forces AM |

Result shapes:

| phrase has | event |
|---|---|
| date + time | timed, `start` = date+time local, `end` = start + 60 min, `all_day` = 0 |
| date only | all-day on that date |
| time only | today (recording's `created_at` date) at that time, `needs_date` = 1 — Brain Dump only |
| neither | all-day today, `needs_date` = 1 — Brain Dump only |

Timezone: the client's local zone at capture time, stored as an IANA name
(`time_zone`) so the server sends `dateTime` + `timeZone` to Google and the
event lands at the spoken wall-clock hour regardless of where the server
runs. All-day events send `date` only.

## Data model

Client DB **v26**, server table, synced entity type `calendar_event`:

```
calendar_events (
  id TEXT PRIMARY KEY,                 -- client uuid
  title TEXT NOT NULL,
  start TEXT NOT NULL,                 -- 'YYYY-MM-DD' (all-day) or ISO local 'YYYY-MM-DDTHH:MM:SS'
  end_ TEXT NOT NULL,                  -- same shape as start
  all_day INTEGER NOT NULL DEFAULT 1,
  time_zone TEXT NOT NULL,             -- IANA, e.g. America/New_York
  needs_date INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'voice',
  source_ref TEXT,                     -- dump id
  capture_fingerprint TEXT,            -- CLIENT-ONLY (todos precedent): sha1(dump id + parsed result)
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
  -- server-authored, projected OUT of device pushes, preserved across upserts:
  google_event_id TEXT, google_html_link TEXT, google_updated TEXT
)
```

Sync: `SyncChange.entity_type` gains `"calendar_event"`; `_apply_calendar_event`
in `server/app/api/sync.py` follows `_apply_todo` (LWW on `updated_at`,
server-only columns preserved, `capture_fingerprint` never stored). Pull
payload includes `google_event_id`, `google_html_link`, `needs_date`.

Server-authored fields flow back through `change_log` like Google Tasks
does, so every device's card shows the link and any date moved in Google.

## Where detection runs (client)

Same two seams as To Do capture, same idempotency rule:
`captureVoiceTodosQuietly` call sites in `server_transcription_service.dart`
(~L758, ~L1134) and `document_sync_engine.dart` (~L403) gain a sibling
`captureVoiceEventsQuietly(dumpId, transcript, mode, createdAt)`.
`capture_fingerprint` keyed on (dump id, parsed events) makes re-transcription
a no-op when nothing changed and adds only new events when it did; never
deletes, never resurrects an Undo.

`mode` is the dump's `DumpMode`; `needs_date` events are produced only for
`brainDump`. `textNote` never captures (no transcript).

## Server worker

`google_calendar_worker.py` beside `google_tasks_worker.py`, run from the
same 5-minute tick after the Tasks cycle, sharing the token/refresh helpers:

1. **Push**: rows with `updated_at > google_updated` (or `google_event_id`
   null): `events.insert` (primary calendar) / `events.patch`. Body:
   `summary`, `start`/`end` (`date` or `dateTime`+`timeZone`),
   `description` = "From Tangent recording: <title>\n tangent://dump/<id>",
   `extendedProperties.private.tangent_id` = row id (lets pull re-match
   after a lost id). Store `id`, `htmlLink`, `updated`.
2. **Delete**: rows with `deleted_at` set and `google_event_id` present →
   `events.delete` (404/410 = already gone = done), then clear
   `google_event_id`.
3. **Pull**: `events.list` on primary with `updatedMin` cursor
   (`google_calendar_cursor` on the link row), `privateExtendedProperty=tangent_id=*`
   is not filterable server-side across ids, so filter client-side on the
   presence of `extendedProperties.private.tangent_id`. Google-newer wins:
   update `title/start/end/all_day` and **clear `needs_date`** when Google's
   date differs from the flagged one (Jeff dragged it — the flag is done
   its job). Google-side `status: cancelled` → soft-delete locally.
   Changes are recorded in `change_log` so devices pull them.
4. **Scope gate**: the link row gains `granted_scope TEXT` (from the token
   response's `scope`). Missing `calendar.events.owned` → status
   `reauth_required`, `last_error` = "Google Calendar permission not
   granted — Reconnect". Tasks keeps working meanwhile: the Tasks cycle
   runs first and the gate applies to the calendar cycle only.

Status (`GoogleTasksStatus`) gains `calendar: {enabled, last_pushed,
last_pulled, last_error}`; Settings → Google shows one extra line
"Calendar: connected · N events".

## Card (client)

`VoiceEventsCard` (`widgets/voice_events_card.dart`), rendered directly
under `VoiceTodosCard` on the recording detail, same conventions (muted
label row `Icons.event` + "Added to your calendar", plain `Card`):

- one row per live event from `watchEventsFromSource(dumpId)`:
  `Dentist · Thu Oct 1, 2:00 PM` / all-day `· Thu Oct 1`.
- flagged: `Dentist · today (no date said) — tap to fix`, amber text.
- before the worker has run: trailing "· syncing…" (no `google_html_link`
  yet); tap does nothing until the link exists.
- tap → `launchUrl(google_html_link)` (external app).
- **Undo** (card-level, like To Do): soft-deletes every event on the card;
  card disappears (it is a view of live rows); worker deletes on Google.
- keys: `voice-events-card-<dumpId>`, `voice-event-row-<eventId>`,
  `voice-events-undo-<dumpId>`.

## Meeting restore (C4)

Revert the UI part of `b607a93`:
- `home_screen.dart`: three-way picker Brain Dump | Meeting | Note, mode
  description line back.
- `dumps_list_screen.dart`: `DumpsCreateAction.meeting` + menu entry.
- tests: `dumps_list_fab_test.dart`, `home_dumps_fab_result_test.dart`
  regain their Meeting cases; `recordings_rename_test.dart` keeps the
  title/hint pins (rename stays).
Nothing else — detail, list, processor, summaries never changed.

## Out of scope (this arc)

- Calendar picker (always primary). `calendar.calendarlist.readonly` not
  requested.
- Attendees, reminders, recurrence, location.
- Editing events inside Tangent (Google owns edits; the card is read-only
  + Undo).
- Manual "Add to calendar" button on a recording (voice only, like To Do
  phase 2).

## Tests

Server: `test_calendar_sync_apply.py` (LWW, server-only projection,
fingerprint never stored), `test_google_calendar_worker.py` (fake Google
HTTP: insert/patch/delete/pull/cancelled, cursor, scope gate →
`reauth_required`, needs_date cleared on a Google-side move), status
shape, version consistency. Client: `voice_date_grammar_test.dart` (To Do
golden unchanged), `calendar_voice_parser_test.dart` (every table row above
+ Meeting skip + time-only rule), `calendar_voice_capture_test.dart`
(idempotency, mode gate, Undo), `voice_events_card_test.dart` (rows,
flagged wording, syncing state, tap disabled until link, Undo), migration
v26 (`userVersion, 26` bumped everywhere), meeting picker + create-menu
widget tests.

Sabotage seams (must fail with quoted text): drop the mode gate (Meeting
no-date event appears), drop the fingerprint (re-capture duplicates), drop
the scope gate (worker calls Google with a tasks-only token), drop
`time_zone` from the insert body, drop the `needs_date` clear on pull.

## Device proof before tagging

Fold, Brain Dump: "…add the dentist Thursday at two to my calendar" →
card row within one worker cycle → tap opens Google Calendar at the event
→ drag it to Friday in Google → card updates on the next cycle. Then a
Meeting recording saying "put that on the calendar" with no date → no
card. Then Undo on the first → gone from Google.
