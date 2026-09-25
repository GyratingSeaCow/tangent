# Summary import into notebooks

Status: APPROVED (Jeff, 2026-09-24: "add in the feature to add in summary notes
or speech bubble while inserting meeting notes into notebooks. This way we can
have both the transcript import and the summary import.")

## Problem

Notebook import ("Import meetings" from the editor's insert menu) offers two
shapes: **Audio bubble** (a playable dump card) or **Text** (the transcript in
an editable text box). Now that meetings carry an AI summary, there is no way
to bring the summary onto a page — only the transcript. Jeff wants both.

## Requirements

1. **Third import shape: Summary.** The `_askImportShape` sheet gains a
   `Summary` option (key `import-as-summary`, icon `auto_awesome_outlined`,
   subtitle "Key points and action items, in an editable text box"). Picking it
   inserts a `NotebookTextBlock` whose text is the dump's summary, laid out
   exactly like the Text shape (same column, same spacing formula).
2. **Both at once.** A fourth option `Transcript + summary` (key
   `import-as-both`, icon `notes` stacked or `library_books`) inserts TWO text
   blocks per dump — summary first, transcript below it — so one import lands
   the whole record.
3. **Honest fallback (mirrors the transcript's).** A dump with no summary
   yet inserts a text box reading `(no summary yet for "<title>")`. Never an
   empty box. For `Transcript + summary`, each block falls back independently.
4. **Gating.** The Summary and Transcript + summary options are shown only
   when at least one picked dump has a non-blank summary OR summaries are
   enabled on this device (`summariesEnabledProvider`). When neither holds the
   sheet shows the two shapes it shows today — the feature is invisible while
   off (OCR/summaries precedent: "while off, none of its UI appears").
5. **Audio bubble carries the summary.** `NotebookDumpCardBlock` rendering
   (`notebook_dump_card.dart`) shows the first line of the summary (the text
   under `## Summary`, truncated to two lines, muted style) beneath the title
   when a summary exists. Absent summary → the card renders exactly as today
   (test-pinned). The bubble is a live view: a summary that arrives later via
   sync appears without re-import.
6. **Domain model.** `Dump` (client/lib/models/dump.dart) gains
   `summary`, `summaryModel`, `summarizedAt` (nullable), mapped from the Drift
   row wherever `DumpRow → Dump` conversion lives. Nothing else reads them yet;
   this is the plumbing the notebook needs.
7. **Markdown in text boxes.** Summaries are markdown (`## Summary` etc.). A
   text block is a plain editor, so inserted summary text is normalised for
   the page: `## Heading` → `Heading` as its own line in the block (the block
   editor has no heading style; keep the line, drop the pounds), bullets `- `
   kept as-is. Implement as a pure function `summaryToPageText(String) →
   String` with tests; the transcript path is untouched.

## Non-goals

- No markdown rendering in the notebook editor (separate item).
- No change to the dump detail screen.
- No new block kind — text blocks and the existing card block are enough.
- No server changes.

## Verification (binding — tangent-app-development verification standard)

- Widget tests on the editor: summary shape inserts one text block with the
  summary; both shape inserts two blocks in summary-then-transcript order;
  no-summary fallback text; gating hides the options when off AND no picked
  dump has a summary; existing card/text shapes unchanged (existing tests stay
  green untouched).
- Card widget test: summary line renders when present, absent-safe pinned.
- Unit tests for `summaryToPageText` (heading strip, bullets kept, blank
  sections, idempotent on plain text).
- Full `flutter test` tally vs the +1716-passing baseline (known 5 by name);
  `flutter analyze` clean; commit green work BEFORE sabotage; ≥1 sabotage
  (absent-safe on the card, or the gating) RED/GREEN quoted.
