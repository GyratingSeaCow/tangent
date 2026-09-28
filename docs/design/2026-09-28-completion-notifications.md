# Completion notifications (2026-09-28) — v1.33.0

Jeff, after the v1.32.0 Regenerate-notes proof: "there is no notification
when the transcribing is done." Today the shade shows ONE progress notice
("Transcribing 1 · large-v3", id 1001) that is CLEARED when the job ends;
nothing announces the result, and AI summaries never touch the shade.

## Picks (controller, low-risk defaults; Jeff can overrule)
- **N1** Two completion notices, each its own fixed id (replace, never
  stack): `Transcribed · <title>` (id 1002) and `Notes ready · <title>`
  (id 1003; body "Meeting notes" / "Summary" by template).
- **N2** Tap opens that recording (`tangent://dump/<id>` — extend the
  existing `tangent://notebook/<id>` VIEW route; same LaunchRouter/
  WidgetLaunch plumbing, new command `open-dump:<id>`).
- **N3** Suppressed when the user is ALREADY on that recording's detail
  screen (a `currentDumpIdProvider` set by DumpDetailScreen); cleared when
  the recording is opened by any path.
- **N4** Fires from where the fact is learned, not from polling:
  transcription — `ServerTranscriptionService` when a queued dump's status
  becomes `transcribed` (or `failed` → `Transcription failed · <title>`,
  same id 1002); summary — `DocumentSyncEngine` when a pull lands a
  non-null `summary` on a row whose `summaryRequestedAt` is set (that is
  exactly the summaryPending contract).
- **N5** Desktop parity via the existing `local_notifier` due-reminder
  path (`DesktopDueReminderPort` pattern): same two notices, click raises
  the window on that recording.
- **N6** A Settings switch "Notify when transcription and notes finish",
  default ON, under the existing Notifications/Reminders block.

## Shape
- `lib/services/completion_notifications.dart` (pure): `CompletionNotice
  {kind, dumpId, title, body}`, `CompletionNotifier` with `announce()`,
  `suppressFor(dumpId)`, `clearFor(dumpId)`; port interface with `show`
  and `cancel(id)`; Null port for tests/unsupported.
- Android port reuses `AndroidTranscriptionNotificationPort` internals
  (channel `completion`, name "Finished work", accent purple).
- Wiring in home_providers next to `transcriptionNotificationOwnerProvider`.

## Tests
- Pure: transcribed → notice 1002 with the title; failed → failed
  wording; summary landed with requestedAt set → 1003 Meeting/Summary
  body; summary landed WITHOUT requestedAt (someone else's device asked)
  → no notice; suppressed while on that dump; clearFor cancels both ids;
  switch off → nothing shown.
- Sync engine: a pull carrying `summary` for a requested row calls the
  notifier exactly once (not again on the next pull of the same row).
- Deep link: `tangent://dump/<id>` cold + warm → detail screen for that id.

## Sabotages
S1 drop the `summaryRequestedAt` gate → "someone else's device" test
fails. S2 fire on every pull → exactly-once test fails. S3 ignore
suppression → on-screen test fails. S4 wrong id for the route → deep-link
test fails.

## Gates
analyze zero; full flutter test (baseline +2586 ~2); Kotlin 123+; device
proof on the Fold: queue a transcription, lock the phone, get the notice,
tap → recording opens; then Regenerate notes → "Notes ready".
