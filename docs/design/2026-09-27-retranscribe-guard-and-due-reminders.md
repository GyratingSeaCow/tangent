# Re-transcription duplicate guard + daily due-date reminder (2026-09-27)

Two independent halves shipped together as **v1.28.0**, client-only.

---

## Half A — re-transcription duplicate guard (#4)

### Problem

`captureVoiceTodos` asks `hasTodosFromSource(dumpId)` before parsing — once
ANY todo exists for a recording, nothing more is captured. That is correct
for repeat arrivals of the SAME transcript. It is wrong when a transcript
CHANGES (re-transcribe with a bigger model, translate, edit): the old
items stay, the new wording never lands, and — worse — the guard fails
open across devices when the first capture never pushed (v1.24.1 gap;
seven `source_ref`s on the live server have 2+ capture devices).

### Rules

1. Capture is keyed by **(dumpId, transcript fingerprint)**, not dumpId
   alone. Fingerprint = SHA-1 of the parsed RESULT (`text|dueDate` per
   entry joined by `\n`), not of the raw transcript — two transcripts that
   yield identical to-dos are the same capture.
2. `todos` gains a LOCAL-ONLY column `capture_fingerprint TEXT NULL`
   (client DB **v25**; NOT in the push payload, NOT read from pull — same
   pattern as `summary_requested_at`).
3. On capture for `dumpId`:
   - existing rows for the source (live or soft-deleted) with the SAME
     fingerprint → do nothing (idempotent, as today).
   - existing rows with a DIFFERENT fingerprint (a re-transcription):
     for each NEW entry, if a live row with identical `text` already
     exists for this source → keep it (update `due_date` only if the new
     parse has one and the row does not); otherwise insert. Old live rows
     whose text is NOT in the new parse are **left alone** (the user may
     have edited them; deleting user data on a re-transcribe is worse than
     one stale item). Soft-deleted rows stay deleted and their text is
     never re-created (Undo remains permanent).
   - no rows → insert all (as today).
4. Cross-device dedupe on PULL: when a `todo/upsert` arrives with
   `source='voice'` and a `source_ref`, and a LOCAL live voice row exists
   with the same `source_ref` + same `text` but a DIFFERENT id, keep the
   row with the smaller `created_at` and soft-delete the other (which
   syncs back as a normal delete). This heals the seven live duplicates
   on the next pull on any device, with no server change.

### Tests (`todo_voice_capture_test.dart`, `todo_sync_test.dart`)

- same transcript twice → no new rows (existing).
- re-transcribe producing one changed item → the changed item is added,
  the unchanged one is kept (same id), the stale one is untouched.
- re-transcribe after Undo → nothing resurrected.
- re-transcribe adds a date to an existing item → `due_date` set, id kept.
- pull of a remote duplicate (same source_ref+text, different id, newer
  created_at) → remote row applied then soft-deleted, local kept; the
  reverse ordering keeps the remote.
- migration v24→v25: column exists, no data change; every schema-pin test
  bumped.

Sabotages: (A1) fingerprint over raw transcript → "identical result from
different wording" test fails; (A2) delete stale rows → "user-edited row
survives" fails; (A3) dedupe ignores soft-deleted → resurrection test
fails; (A4) dedupe compares ignoring `source_ref` → two different
recordings with the same item text collapse (test fails).

---

## Half B — daily due-date reminder (#5), Android only

### Jeff's picks (recorded)

- **N1 07:00 local, changeable in Settings** (hour + minute picker).
- **N2 ONE morning digest**: title `Due today` (or `Nothing due today` is
  NOT sent — no notification when the list is empty), body
  `call the dentist, pay the water bill · 1 overdue` (items due today
  comma-joined, truncated to 3 + "and N more"; ` · N overdue` suffix when
  any live item is past due). Tap opens the To Do screen.
- **N3 Android now**; Linux/Windows follow-up (the section is hidden on
  desktop, not disabled).
- **N4 Off by default.** Settings → **Reminders** section: switch
  `reminders-enabled`; turning it on requests `POST_NOTIFICATIONS` (and on
  Android 12+ checks `canScheduleExactAlarms`; if refused, fall back to
  inexact and say so in the section's status line — never silently
  nothing). Time row `reminders-time` (disabled while off). Status line
  `reminders-status`: "Next: tomorrow 7:00 AM" / "Notifications blocked —
  open system settings" (button `reminders-open-settings`).

### Mechanics

- `services/due_reminder_scheduler.dart`: `scheduleNext(now, hhmm)` →
  ONE `zonedSchedule` at the next `hhmm` strictly after `now`
  (`flutter_local_notifications` 17.x, `AndroidScheduleMode.
  exactAllowWhileIdle`, falling back to `inexactAllowWhileIdle` when exact
  is not permitted), channel `due_reminders` ("Due-date reminders",
  importance default). Add `timezone` + `flutter_timezone` deps for tz
  init — the existing transcription channel does not schedule.
- The BODY is computed at FIRE time, not schedule time: on Android that
  means the notification is *posted* by a `workmanager` one-off task
  registered for the same instant (`tangent.dueReminder.daily`, exact
  alarm wakes it) which reads the DB, builds the digest, shows (or skips
  when empty) and re-schedules the next day. Reuse the existing
  `callbackDispatcher` in `main.dart` (add a second task name; keep the
  document-sync branch untouched).
- Re-schedule on: app start, toggle on, time change, device reboot
  (`RECEIVE_BOOT_COMPLETED` + the plugin's boot receiver). Cancel on
  toggle off.
- Deep link: notification payload `todo`; `main.dart`'s launch handler
  pushes the To Do route (same mechanism the transcription notification
  uses to open a recording — find it, reuse it).
- Manifest: `SCHEDULE_EXACT_ALARM` (maxSdk 32) + `USE_EXACT_ALARM` (33+),
  `RECEIVE_BOOT_COMPLETED`, the plugin's `ScheduledNotificationReceiver`
  and `ScheduledNotificationBootReceiver`.
- `SettingsStore`: `remindersEnabled` (bool, default false),
  `reminderMinuteOfDay` (int, default 420 = 07:00).

### Digest rule (pure, unit-tested): `buildDueDigest(todos, today)` →
`DueDigest?` `{title, body, dueTodayCount, overdueCount}`; null when
nothing is due today AND nothing overdue. Overdue = live, `due_date <
today`. Done and soft-deleted rows excluded. Sorted by text.

### Tests

- digest: empty → null; 2 today → both names; 5 today → 3 names + "and 2
  more"; overdue-only → title `Overdue`, body `N overdue: …`; done/deleted
  excluded; text sort.
- scheduler: `nextFireTime(now 06:59, 07:00)` = today 07:00; `now 07:00`
  = tomorrow (strictly after); minute-of-day round-trips through the
  store.
- Settings section widget: hidden on non-Android (`Platform` seam via a
  provider), switch off by default, time row disabled while off, enabling
  calls the permission seam and schedules, disabling cancels; status line
  text for granted / denied.
- Sabotages: (B1) `>=` instead of `>` in nextFireTime → fires today at
  07:00 when it is already 07:00 (test fails); (B2) digest includes done
  rows; (B3) toggle off does not cancel; (B4) empty digest still posts.

### Device proof (Jeff, Fold)

Settings → Reminders → on → allow → set the time to two minutes from now
→ lock the phone → notification `Due today: call the dentist …` arrives →
tap → To Do screen opens. Then set it back to 7:00.

---

## Gates

`flutter analyze` zero issues; full suite green (baseline +2420 ~2).
Server untouched (version number kept uniform).
