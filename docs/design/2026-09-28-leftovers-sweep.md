# Leftovers sweep (2026-09-28) — v1.32.0

Five deferred "Open:" items from `docs/next-iteration.md`, one release,
client-only. Each keeps its old behaviour reachable so nothing regresses.

## L1 — Regenerate notes uses the AI summarizer
Today `dump_detail_screen.dart` ~line 837 runs `MeetingNotesProcessor`
(rule-based, ms-fast, same output every time). Change: when the server
reports the summarizer installed (the same readiness the Summarize button
already checks), *Regenerate notes* requests a server summary with the
**Meeting** template through the existing summarize path (202 →
`summary_requested_at` → in-progress card → `meeting_notes` lands from the
worker). When the summarizer is NOT installed (or offline), keep the
extractor exactly as today. Button copy: 'Regenerate notes' → spinner
'Regenerating…' as now; the in-progress card explains which engine ran
("AI summary (Meeting)" vs "Quick notes"). Test: with a fake client
reporting installed → one summarize request with template `meeting`, no
extractor call; not installed → extractor, no request. Sabotage: swap the
gate → both tests fail.

## L2 — Stamps shift on edits before them
`stamp_reconcile.dart` `reconcileStamps(old, new, stamps)` drops a stamp
whose offset no longer matches. Change: compute a common-prefix /
common-suffix diff between old and new text; stamps entirely inside the
unchanged prefix keep their offset, stamps entirely inside the unchanged
suffix shift by `new.length - old.length`, stamps overlapping the changed
middle are dropped (as today). Tests: insert before → shifted; delete
before → shifted back; edit after → unchanged; edit through a stamp →
dropped; replace-all → all dropped; idempotent on identical text.
Sabotage: shift by the wrong sign → the delete-before test fails.

## L3 — Meeting-notes digest renders speaker names
`MeetingNotesProcessor.process` receives the raw transcript with
`## Speaker N`. Change: the caller passes the transcript through the
existing `renderSpeakerNames` (render_speaker_names.dart) with the dump's
`speakerNames` map BEFORE processing, so extracted lines say "Jeff" not
"Speaker 1". Stored transcript untouched. Test: map {Speaker 1: Jeff} →
notes contain 'Jeff', not 'Speaker 1'; empty map → unchanged output.
Sabotage: skip the render → test fails.

## L4 — Word-level inline timestamps in Markdown export (E1=b)
Export options gain `wordTimestamps` (default OFF, remembered like the
other two). When ON and `transcript_timings` word data exists, each
segment line becomes `[mm:ss] Name: word⟨mm:ss.d⟩ word …`? — NO: too
noisy. Format: every 10th word (and the first word of each segment)
carries a superscript-style marker `word⁽mm:ss⁾`; segments without word
timings fall back to the segment line unchanged. With the toggle OFF the
file is byte-identical to v1.16.0 output (pin with the existing golden
test). Obsidian export sheet shows the third switch only when word
timings exist for that recording. Tests: on/off byte-identity, marker
cadence, fallback. Sabotage: drop the byte-identity guard (emit markers
when off) → golden fails.

## L5 — Surface refused speaker back-fill once
`planSpeakerNamesBackfill` returns null for ambiguous pairings and the
migration (local_db.dart ~935) silently skips. Change: the migration
records skipped dump ids in `app_settings['speaker_backfill_skipped']`
(JSON list, local-only). Home shows a one-time dismissible banner "N
recordings kept their old speaker headings — open one to name speakers
again"; tapping opens the Recordings list filtered to those ids; dismiss
clears the key. Test: migration with one ambiguous transcript → key set;
banner shows with count; dismiss → key cleared → banner gone; no skips →
no banner. Sabotage: never write the key → banner test fails.

## Gates
`flutter analyze` zero; full `flutter test` green (baseline +2546 ~2).
Real proofs on the Fold: L1 — tap Regenerate notes on a meeting recording
with the summarizer installed → in-progress card → AI notes; L3 — notes
show the named speaker; L4 — export a recording with timings, toggle on,
see markers; L2/L5 by tests (L5 needs a pre-1.17 transcript, none live).
