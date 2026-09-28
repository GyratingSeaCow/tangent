# Desktop reminders + voice-date follow-ups (2026-09-27)

Two independent halves, shipped together as **v1.29.0**, client-only.

---

## Half A — daily due-date reminder on Linux + Windows (#1)

v1.28.0's reminder is Android-only (`isAndroidProvider` hides the section
elsewhere). The digest rule (`buildDueDigest`), the strictly-after
`nextFireTime`, the `DueReminderScheduler`, the `DueReminderPort` seam and
the Settings section all exist and are tested. This half adds a DESKTOP
port and lifts the gate.

### Jeff's pick (recorded)

- **K1 Missed reminders are shown on next launch**, once per day: if the
  app was not running at the chosen time, the first launch that day
  (after the time) shows the digest with the title prefixed
  **`Missed 7:00 · Due today`**. Never twice for the same day.

### Mechanics

- **`DesktopDueReminderPort`** (`services/desktop_due_reminder_port.dart`)
  implements `DueReminderPort` with the `local_notifier` package (0.1.6 —
  Windows toast + Linux libnotify; add to pubspec):
  - `requestNotificationPermission()` → `true` (desktop has no runtime
    permission; Linux without a notification daemon simply shows nothing
    — the status line still says "Next: …", that's acceptable).
  - `canScheduleExact()` → `true`.
  - `schedule(fireAt, digest, exact)` → an in-process `Timer` to `fireAt`
    (the desktop app is long-running: close-to-tray keeps the process
    alive). At fire time re-read the DB via the scheduler's `loadTodos`
    (the port receives a `Future<DueDigest?> Function()` callback — NOT
    the predicted digest — desktop has no alarm/worker split so it always
    builds live), post or skip, record `lastReminderShownDay`, re-arm for
    the next day. Timers are cancelled and re-armed on system
    **resume-from-sleep** (a `Timer` that slept through its deadline
    fires immediately on wake — that is fine and counts as "on time" if
    the day matches; see K1 test).
  - `post(digest)` → `LocalNotification(title, body)`; **onClick** → show
    the window (reuse the tray's show path — `windowManager.show()` +
    `focus()`) and push the To Do route on `TangentApp.navigatorKey`
    (same as Android's warm tap).
  - `withdraw()` / `cancel()` → close the last notification / cancel the
    timer.
  - `openSystemSettings()` → no-op (nothing to open); the section hides
    the *Open system settings* button when `canOpenSystemSettings` is
    false (new optional getter on the port, default true).
- **K1 catch-up**: `SettingsStore.lastReminderShownDay` (String
  `YYYY-MM-DD`, default ''), written by BOTH ports after a successful
  post (Android: in the workmanager task). On desktop app start, if
  `remindersEnabled` and `now.minuteOfDay >= reminderMinuteOfDay` and
  `lastReminderShownDay != today` → build the digest live; if non-null
  post it with the `Missed H:MM · ` prefix and record the day. Then arm
  the normal timer for tomorrow. (Android needs no catch-up — the alarm
  survives the app being closed; leave Android's start path unchanged
  except for writing the pref.)
- Platform gate: `isAndroidProvider` → `remindersSupportedProvider`
  (`Platform.isAndroid || Platform.isLinux || Platform.isWindows`);
  section copy: "Shows a system notification…" on desktop. Wire the
  right port in `main.dart` by platform; keep the Android branch
  byte-identical apart from the pref write.

### Tests

- `DesktopDueReminderPort` with a fake `LocalNotifier` seam + fake clock:
  schedule → timer fires at `fireAt` → live loader called → post; empty
  digest → no post, day NOT recorded; cancel before fire → nothing.
- catch-up: enabled, 09:00 > 07:00, day unrecorded → posted with
  `Missed 7:00 · ` prefix, day recorded; same day again → nothing;
  06:00 (before the time) → nothing; disabled → nothing.
- section visible on Linux/Windows via the provider override; *Open
  system settings* hidden when the port says so.
- Existing Android tests unchanged (+ one asserting the pref is written).

Sabotages: (A1) catch-up ignores `lastReminderShownDay` → "same day
again" fails; (A2) desktop `schedule` posts the predicted digest instead of
loading live → "live loader called" fails; (A3) catch-up runs before the
chosen time → the 06:00 test fails; (A4) gate stays Android-only → Linux
visibility test fails.

Gate: `flutter analyze` clean, full suite green (baseline +2467 ~2), AND
`flutter build windows --release` succeeds (plugin wiring). Proof on the
PC: enable, set time two minutes out, wait → Windows toast; click → To Do;
then close the app, set the time to one minute ago, relaunch → `Missed …`
toast.

---

## Half B — voice-date follow-ups (#4)

Extends the v1.26/v1.27 parser. All picks recorded:

- **V1 Times of day are kept as text, the date is taken.** "call mom
  tomorrow at 3 pm" → `call mom at 3 pm`, due tomorrow. The time phrase
  (`at 3`, `at 3 pm`, `at 3:30`, `at noon`, `at midnight`, `around 3`,
  `3 o'clock`) is recognised only so the date phrase NEXT TO IT can be
  removed cleanly — the time itself is never stripped and never parsed
  into a value. Nothing new syncs.
- **V2 `this weekend` = the coming Saturday** (strictly after recordedOn;
  said on a Saturday → next Saturday, consistent with R1). `next
  weekend` = the Saturday after that.
- **V3 Bare day-of-month**: `on the 15th` / `by the 1st` / `the 31st` →
  the next such day-of-month on or after recordedOn; if that month has
  no such day (the 31st in September) → the next month that does.
  Requires the ordinal suffix (`15th`) — bare `on 15` is text.
- **V4 `a week from <weekday>` / `a week from tomorrow` / `a week from
  today`** → resolve the inner phrase, +7. `two weeks from Friday` → +14.
- **V5 `end of the day`/`tonight`/`this morning`/`this afternoon`/`this
  evening`** → today (a date-only model; the time-ish word is kept as
  text per V1 — "call mom tonight" → `call mom tonight`, due today? NO:
  these words carry the date AND are natural in the text; strip nothing,
  set due = today).

Position rules unchanged: sentence head, item start, item end; middle of
an item stays text. When a date phrase and a time phrase are adjacent at
an item's end in either order (`tomorrow at 3 pm`, `at 3 pm tomorrow`),
the date phrase is removed and the time phrase stays in place: `call mom
at 3 pm`.

### Fixtures (verbatim in tests; recordedOn 2026-09-27, Sunday)

1. `Add to my to-do list, call mom tomorrow at 3 pm.` → `[call mom at 3 pm]` due `2026-09-28`
2. `Add to my to-do list, call mom at 3 pm tomorrow.` → `[call mom at 3 pm]` due `2026-09-28`
3. `Add to my to-do list, mow the lawn this weekend.` → `[mow the lawn]` due `2026-10-03`
4. `Add to my to-do list, pay rent on the 15th.` → `[pay rent]` due `2026-10-15`
5. `Add to my to-do list, pay rent on the 31st.` recorded 2026-09-27 → due `2026-10-31` (September has no 31st)
6. `Add to my to-do list, renew the plates a week from Friday.` → `[renew the plates]` due `2026-10-09`
7. `Add to my to-do list, call mom tonight.` → `[call mom tonight]` due `2026-09-27` (V5: nothing stripped)
8. `Add to my to-do list, meet Dana at 3.` → `[meet Dana at 3]`, no date (time alone is not a date)
9. `Add to my to-do list, pay rent on 15.` → `[pay rent on 15]`, no date (V3 needs the suffix)
10. `Add to my to-do list, mow the lawn this weekend.` recorded Saturday 2026-10-03 → due `2026-10-10` (V2/R1)

Sabotages: (B1) time phrase stripped → fixture 1 yields `[call mom]`; (B2)
`this weekend` = Sunday → fixture 3 yields `2026-10-04`; (B3) bare
day-of-month accepts no suffix → fixture 9 gets a date; (B4) `a week from`
forgets +7 → fixture 6 yields `2026-10-02`; (B5) V5 strips the word →
fixture 7 yields `[call mom]`.

Gate: analyze clean, full suite green. Proof: Jeff records *"Add to my
to-do list, call the plumber tomorrow at 9 am"* → `call the plumber at 9
am`, chip **Mon Sep 28**.
