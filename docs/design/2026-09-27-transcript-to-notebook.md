# Transcript → notebook (v1.20.0)

Decided with Jeff 2026-09-27: **N1=a** both directions, **N2=a** rendered
transcript (names + `[mm:ss]` per turn), **N3=y** tappable stamps.

Client-only. No server change, no DB schema change. Notebook document JSON
gains one optional field on text blocks (backwards compatible).

## Problem

Today the only way to get a recording onto a page is: open the notebook →
insert menu → *Import meetings* → pick dumps → pick shape (Audio bubble /
Text / Summary / both). The Text shape inserts the RAW transcript
(`## Speaker 1` headings, no times). Jeff wants (1) to start from the
recording, (2) the transcript to read like the v1.16 Markdown export, and
(3) the times to be live.

## A — "Send to notebook…" from the recording (N1=a)

- New `ItemAction.sendToNotebook` in `client/lib/widgets/item_action_sheet.dart`
  (icon `menu_book_outlined`, label "Send to notebook…", placed after
  `exportMarkdown` in `_canonicalOrder`). Offered on the recordings-list ⋮
  and the detail overflow, for any dump with a non-blank transcript OR
  summary (same gate as the existing import shapes). Multi-select on the
  list sends all selected dumps to the one chosen notebook.
- Tapping it opens **`NotebookPickerSheet`** (new,
  `client/lib/widgets/notebook_picker_sheet.dart`): a searchable list of
  notebooks from `NotebookRepository.watchNotebooks()` sorted by
  `updatedAt` desc, plus a first row **"New notebook"** that creates one
  titled after the dump (`createNotebook(title: dump.title)`) and picks it.
  Keys: `notebook-picker`, `notebook-picker-new`, `notebook-picker-<id>`.
- Then the SAME shape sheet the editor uses (`_askImportShape` — extract
  it to `client/lib/screens/notebook/import_shape_sheet.dart` as a public
  `askImportShape(context, {offerSummary})` so both call sites share one
  widget and one test).
- Insertion happens WITHOUT opening the editor: a new service
  `client/lib/services/notebook_import.dart::importDumpsIntoNotebook({
  notebookId, dumps, shape, timings, speakerNames })` loads the document
  through `NotebookPersistence`, appends the blocks using the editor's
  existing layout formula (extract `_layoutImportedBlocks` from the editor
  into the service so the editor calls the same function — one code path),
  saves, marks dirty for sync. Snackbar: "Added to <notebook title>" with an
  **Open** action that pushes the editor scrolled to the first new block.
- The in-notebook *Import meetings* path is unchanged in behaviour; it now
  calls the shared service.

## B — Rendered transcript block (N2=a)

- New pure function `client/lib/services/transcript_page_text.dart::
  transcriptPageText({dump, timings, speakerNames}) → TranscriptPageText`
  producing the block text and its stamp map. Rules (mirror
  `transcriptMarkdown` from v1.16 — reuse its helpers `resolveSpeakerNames`,
  `needsHourStamps`, `formatSegmentStamp`; do not fork them):
  - One paragraph per speaker turn: `[mm:ss] Jeff: text…` (`h:mm:ss`
    for the whole block once any turn passes an hour). Names from the
    speaker-name map first, heading-pairing fallback second, raw
    `Speaker N` last — identical to the export.
  - Blank line between turns. No `##` headings, no frontmatter.
  - No timings (local-only transcription, or a pre-v1.12 dump) → turns
    without stamps: `Jeff: text…`. Never fake a time.
  - No speakers at all (single-speaker mono transcript) → plain paragraphs,
    stamped per timing segment when timings exist.
- The Text and Transcript + summary shapes now insert THIS text. The
  Summary shape is unchanged. Keep the old raw behaviour reachable? **No** —
  Jeff chose a; the rendered form replaces it. The honest fallback
  `(no transcript yet for "<title>")` stays.

## C — Tappable stamps (N3=y)

- `NotebookTextBlock` gains an optional `stamps` field:
  `List<TextStamp>` where `TextStamp{int offset, int length, double
  seconds, String dumpId}` — character ranges inside `text` that are live.
  JSON: `'stamps': [{'o':…, 'l':…, 's':…, 'd':…}]`, omitted when empty.
  Older builds ignore the key (the parser already tolerates unknown keys —
  pin that with a test). `copyWith(text:)` on a stamped block MUST re-map
  or drop stamps: simplest correct rule — if the user edits the block text
  at all, stamps whose range no longer starts with `[` are dropped (a pure
  `reconcileStamps(oldText, newText, stamps)` with tests; no diffing
  heroics).
- Rendering: in the block editor, when the block is NOT focused for
  editing, stamp ranges render as tappable spans (accent colour,
  underline-dotted, key `stamp-<blockId>-<index>`). When the block is being
  edited they render as plain text (no taps while typing).
- Tap behaviour, in order:
  1. If a `NotebookDumpCardBlock` for the same `dumpId` exists on the page
     AND its audio is playable locally → seek that card's player to
     `seconds` and play (the card already has a player; expose a
     `seekAndPlay(Duration)` on its state via a `GlobalKey`/controller map
     the editor owns).
  2. Else if the audio is local → push `DumpDetailScreen` with a new
     optional `initialSeekSeconds` that calls the existing `_seekAndPlay`
     after the player is ready.
  3. Else (audio on server only) → push detail as in 2; detail already
     shows "Audio is on the server. Download it to play." — no new UI.
- The `Transcript + summary` and `Text` shapes insert an Audio bubble
  card automatically **only when the shape sheet's new switch "Include
  audio bubble" is on** (default ON, remembered in SettingsStore key
  `notebook-import-audio-card`). This is what makes rule 1 the common
  case.

## Non-goals

- Editing a stamp's time; stamps are import-time facts.
- Markdown rendering in text blocks (still a separate item).
- Karaoke highlight inside the notebook block.
- Server or sync changes (the notebook document already syncs as a blob).

## Verification (binding)

Unit: `transcriptPageText` — names from map, fallback pairing, raw labels,
hour promotion, no-timings → no stamps, mono transcript, stamp offsets
point exactly at `[` and cover the bracket; `reconcileStamps` drop/keep
cases; block JSON round-trip with and without stamps; unknown-key
tolerance.

Widget: (1) list ⋮ → Send to notebook → picker → New notebook → shape Text
→ snackbar with Open → editor shows one text block whose first line is
`[00:00] Jeff: …` plus an audio card; (2) same from detail overflow; (3)
in-editor Import still works and inserts the rendered text; (4) tapping
`stamp-…-0` with a card on the page calls the card's `seekAndPlay(0s)`
(fake engine records the seek), and with NO card pushes DumpDetailScreen
with `initialSeekSeconds`; (5) editing the block turns stamps off while
focused and drops broken ones after.

Real-data proof before merge: import Jeff's 2026-09-26 19:39 recording
(two speakers, name map `{Speaker 1: Jeff}`) into a scratch notebook on
the Fold; screenshot the page; tap a stamp mid-recording and confirm
playback position on the card.

Sabotages: (a) `transcriptPageText` ignores the name map; (b) stamp
offsets off by one; (c) `reconcileStamps` keeps broken stamps.
