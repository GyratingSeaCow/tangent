# To Do phase 2 — voice capture from a brain dump + checkbox icon

Date: 2026-09-27 · Status: approved (Jeff's picks recorded below)
Builds on: `docs/design/2026-09-27-todo-section.md` (phase 1, already
implemented on `feature/todo-client` + `feature/todo-server`).

## Decisions (Jeff, 2026-09-27)

- **I1 — home icon.** The To Do entry point is a **checked checkbox**
  (`Icons.check_box`) in the top-right AppBar, not `Icons.checklist`.
  Phase 1 shipped `Icons.checklist`; change it, keep the key
  `home-todo-button` and tooltip 'To Do'.
- **V1 — capture span.** Everything after the trigger phrase to the END
  of the transcript, split into separate items on commas / "and".
- **V2 — trigger family** (not a single exact phrase): "add to my to do
  list", "add to my todo list", "add that to my list", "remind me to",
  "put on my to do list". Match case-insensitively, tolerate an
  optional trailing colon, and tolerate "todo"/"to-do"/"to do" spelling.
  No Settings UI for custom phrases in this arc.
- **V3 — visible auto-add.** Items are added automatically; the
  recording's detail screen shows a card listing exactly what was
  added, with **Undo**.

## Where the detection runs

**Client-side, on transcript arrival** — NOT in the server pipeline.
Rationale: the trigger works for any transcript regardless of which
engine produced it, it needs no server redeploy to tune the phrase
list, and phase 1's todos are already client-authored and synced (so an
auto-added item syncs like a typed one for free). The server half stays
exactly as merged.

Hook point: wherever the client first persists a completed transcript
for a dump (grep the transcript-arrival path used by
`summary_status`/transcript repair — likely `document_sync_engine`'s
dump apply or the local transcription completion path; find the ONE
place both local and server transcripts land, and hook there so both
paths get it). Must be idempotent: the same dump transcript arriving
twice (re-sync, re-transcribe) must NOT duplicate items.

## Parsing rules (`TodoVoiceParser`, pure function, unit-tested)

Input: transcript text. Output: `List<String>` items, in order.

1. Find the FIRST trigger-phrase match (case-insensitive, allowing an
   optional `:` and the to-do spelling variants).
2. Take everything from the end of that phrase to the end of the
   transcript.
3. Split on `,` and standalone " and " (case-insensitive, word
   boundaries — never inside a word like "brand").
4. Trim whitespace, strip a leading "to " left by "remind me to",
   strip trailing periods, drop empties, collapse internal whitespace.
5. Cap: at most 20 items; each item truncated to 200 chars.
6. If the span after the trigger is empty/whitespace → NO items, no
   card (saying the phrase alone does nothing).
7. "remind me to" keeps its own semantics: the item text is what
   follows, same splitting.

Edge cases that MUST have tests: trigger at the very end with nothing
after; trigger appearing twice (first one wins, span runs to the end so
the second is inside the span — its phrase text stays as written);
"and" inside an item's words; a comma-less single item; mixed case;
"to-do" hyphenated; an item that is only punctuation.

## Data / provenance

Auto-added todos use phase 1's reserved fields: `source = 'voice'`,
`source_ref = <dump id>`. Idempotency key: never create voice todos for
a dump that already has any todo with that `source_ref` (query first).

## UI — the added card

On the recording detail screen, below the transcript card (near the
summary card's position — match its visual conventions), when the dump
has voice-added todos:

- Title: "Added to your To Do list"
- The items as a plain bulleted list (text only, no checkboxes here)
- **Undo** action: soft-deletes exactly the todos created from this
  dump (by `source_ref`), the card then disappears; a snackbar confirms.
  Undo is permanent for that dump — after undo, detection does not
  re-fire for it (the idempotency query counts soft-deleted rows too,
  so re-sync can't resurrect them).
- Tapping the card body opens the To Do screen.
- The card is NOT shown when the dump produced no voice todos.

## Tests

- Parser unit tests: every rule + every edge case above.
- Repository/integration: transcript arrival creates todos with
  `source='voice'` + `source_ref`; the SAME transcript arriving twice
  creates nothing new; after Undo, a third arrival still creates
  nothing.
- Widget: card lists exactly the added items; Undo removes them and
  hides the card; no card when no trigger; tap opens the To Do screen.
- Widget: home AppBar shows `Icons.check_box` (assert the ICON, not
  just the key — the key already passes today with the wrong icon).

## Sabotage (named, required)

- (e) Parser splits on every " and " INCLUDING inside words → the
  word-boundary test fails.
- (f) Drop the idempotency query (always insert) → the
  duplicate-arrival test fails.
- (g) Revert the icon to `Icons.checklist` → the icon test fails
  (proves the assertion is on the icon, not the key).
- (h) Undo hard-deletes instead of soft-deleting → the
  "no resurrection after re-sync" test fails.

## Proof before merge (device)

On the S11 Ultra: record a brain dump saying "customer board is toast,
add to my to do list pick up thermal paste and email the Zionsville
customer back" → wait for the transcript → the card lists BOTH items →
open To Do (checkbox icon, top right) → both items are there under
Someday → they appear on the Fold after sync. Screenshot both.

## Release

Rides **v1.23.0** with phase 1 (server + client merge atomically).
Server untouched by this phase; the v1.23.0 release still needs the DB
backup + container redeploy for phase 1's server half.
