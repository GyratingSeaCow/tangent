# Page backgrounds (graph + dot grid, top-right menu) — v1.22.0

Date: 2026-09-27 · Status: approved (Jeff's picks recorded below)

## Decisions (Jeff, 2026-09-27)

- **B1 — styles: 5 total.** Blank, Lined (small), Lined (medium) — existing —
  plus **Graph** (grid squares) and **Dot grid**.
- **B2 — a real picker, not a cycle.** Tap *Page background* → bottom sheet
  with a labeled preview swatch per style; tap one to apply. The old
  each-tap-cycles behavior dies with the move.
- **B3 — new top-right hamburger menu holds ONLY the picker for now.**
  Keep it small; more items may move there later, not in this arc.
- **Placement (Jeff, verbatim intent):** the page-background control MOVES
  out of the bottom-left insert (+) menu into a new hamburger menu in the
  top-right of the editor's AppBar.

## What the user sees

- A hamburger icon (`Icons.menu` — if the AppBar row gets crowded next to
  search/save, `Icons.more_vert` is the acceptable fallback [default:
  menu]) appears at the END of the editor AppBar actions (right of Save).
- Tapping it opens a menu with one item: **Page background** (leading
  icon, e.g. `Icons.grid_4x4` or similar outline icon; trailing text of
  the CURRENT style, so the closed menu answers "what is this page").
- Tapping *Page background* opens a bottom sheet: five entries, each a
  small preview swatch (a mini CustomPaint rendering that style's actual
  painter output at reduced spacing — not a bitmap asset) + label. The
  current style is visibly selected (check mark / accent border). Tap
  applies immediately, closes the sheet, marks the notebook dirty; the
  choice persists per notebook exactly as `ruling` does today.
- The insert (+) menu at the bottom LOSES its `Page: <label>` item
  (`notebook-ruling-item`). Everything else in that menu stays.

## Model / wire

Extend the existing `NotebookRuling` enum (client-only feature; server
passes notebook payloads through — grep server/ for 'ruling' to confirm
no change needed, same as the original ruling arc):

- `graph` — square grid. Spacing: 5 mm quad rule ≈ **32 logical px**
  (same mm→px basis as the doc comment in notebook_ruling.dart:
  6.3 px/mm on the reference Tab S10 FE). Vertical AND horizontal lines,
  same `TangentColors.edge` colour, strokeWidth 1.
- `dots` — dot grid. Same 32 px spacing; dots as ~1.5 px radius filled
  circles at the intersections, `TangentColors.edge`.
- Wire values: `graph`, `dots` via the existing `wireValue`/`parse`
  round-trip. `parse` already falls back to blank for unknown values, so
  OLDER builds opening a graph/dots notebook render blank and PRESERVE
  the stored value (the enum's own doc promises this — do not break it).
- Labels: 'Graph', 'Dot grid'. Existing three labels unchanged.
- `lineSpacing` for graph/dots returns 32; the PAINTER decides how to
  draw each style. Restructure `NotebookRulingPainter.paint` on a switch
  over the enum: blank → return, small/medium → horizontal lines
  (byte-identical output to today — pinned), graph → both directions,
  dots → circles. `shouldRepaint` unchanged (identity compare).

## Client changes

Files: `client/lib/models/notebook_ruling.dart`,
`client/lib/screens/notebook/notebook_editor_screen.dart` (CRLF),
new `client/lib/widgets/page_background_sheet.dart` (sheet + swatches),
tests.

1. **Enum + painter** as above. Painter guard (zero/non-finite) stays
   first — the infinite-width crash comment is history, respect it.
2. **AppBar**: add the hamburger `PopupMenuButton` (or IconButton →
   menu) with key `ValueKey('notebook-menu')`, disabled while
   `_notebook == null` like Save. One entry, key
   `ValueKey('notebook-page-background-item')`, label 'Page background',
   subtitle/trailing = current `_ruling.label`.
3. **Sheet**: `showModalBottomSheet`, five `ListTile`-ish rows with a
   swatch (SizedBox ~72×48 CustomPaint of the real painter at that
   style) + label + selected marker. Returns the picked ruling or null
   (dismiss = no change — pin that, same rule as the ink palette).
   Apply via the existing `_ruling = …; _dirty = true` path `_cycleRuling`
   used; delete `_cycleRuling` and the `_InsertAction.cycleRuling` case +
   menu item.
4. **Persistence**: nothing new — `ruling` already rides `copyWith`,
   Drift column (TEXT name), sync payload, `applyRemoteNotebook`
   fallback, and `_save`. The enum gains values, the plumbing is done.
   BUT: the repository real-SQL round-trip test gets two new cases
   (graph, dots) — the `saveNotebook` Companion hole from the original
   ruling arc is exactly the class of bug that would eat these silently.

## Tests

- Painter unit tests (recording canvas, per existing painter-test
  conventions — the recorder THROWS on unrecorded draw calls):
  - small/medium output byte-identical to today (same line positions),
  - graph draws verticals + horizontals at 32 px,
  - dots draws circles at intersections and NO lines,
  - blank draws nothing; zero/non-finite guard intact.
- Wire: `parse('graph')`/`parse('dots')` round-trip; unknown → blank.
- Widget tests (editor):
  - hamburger menu exists top-right, opens, shows current label,
  - picking Graph from the sheet applies it (canvas repaints with the
    graph painter — assert through the mounted painter's ruling), marks
    dirty, and SURVIVES save→reopen through the real-SQL round trip,
  - dismissing the sheet changes nothing,
  - the insert menu NO LONGER contains `notebook-ruling-item` (pin its
    absence),
  - legacy: a notebook stored with `small` still opens ruled small.

## Sabotage (named, required)

- (a) Make the sheet's dismiss path reset to blank → the dismiss test
  fails, quote, restore, re-pass.
- (b) Drop the horizontal pass from graph (paint only verticals) → the
  graph painter test fails, quote, restore, re-pass.
- (c) Remove `ruling` from ONE `NotebooksCompanion` write path → the
  real-SQL round-trip test fails (this is the historical hole; prove the
  test still guards it with the new values).

## Proof before merge (device)

On the S11 Ultra: open a notebook → hamburger → Page background → pick
Graph → grid appears under existing ink; write a line; close and reopen
→ still graph. Switch to Dot grid → dots. Screenshot each. Confirm the
insert (+) menu no longer offers Page.

## Versioning / release

Client-only → bump `client/pubspec.yaml` to **1.22.0+27** only; server
untouched (verify with the grep). CHANGELOG entry; usual ship gates.
