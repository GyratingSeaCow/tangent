# T4 — Notes/Notebooks page (design contract)

Jeff's request (verbatim, from the backlog):

> we also need a page for notes/notebooks to be able to made from the top menu.
> There needs to be the ability to type, insert checkboxes, and even select the
> dumps you want to add and have them appear as little floatin boxes you can drag
> around. Similar to how Samsung notes allows you to insert voice notes into their
> system. There also needs to be stylus support so you can write white on a black
> background. If you can, import the pen types from samsung notes or something
> similar. If you can't then simply make it a round pen input that is adjustadble
> in size at the top in the menu of that page alone.

## Settled decisions (orchestrator-owned — workers MUST NOT redesign)

### Scope phasing
- **This iteration (Jeff authorised 2026-09-17, "yes. put it in this round"):**
  local SQLite persistence PLUS durable publication so notebooks survive an
  uninstall exactly like recordings and text notes.
- Durable form: one `<id>.notebook.json` per notebook published into a
  `Tangent Notebooks/` child directory of the selected Tangent folder, written
  through the SAME `NotePersistence`/SAF publication path text notes use.
  Publication carries the full document: title, timestamps, `doc_json`,
  `ink_json`. On folder import, `.notebook.json` files are re-adopted into the
  `notebooks` table (id is the durable identity; newer `updated_at` wins).
- Server sync of notebooks remains OUT of scope (Jeff wants local-only files;
  only transcription goes to the server).
- Risk note kept deliberately: the SAF layer produced three production bugs this
  iteration, so the durable step lands as its OWN task after the data layer and
  widgets are green, and must reuse the existing publication helpers rather than
  writing a second publication path. MIME-coherent temp names
  (`.partial.json`) and the opaque-document-ID rules are non-negotiable.
- Samsung Notes pen types are proprietary and NOT importable. Jeff's authorised
  fallback applies: a round pen with adjustable stroke size, controlled from the
  notebook page's own toolbar ONLY (never global settings).

### Data model — client schema v5 → v6
One new table, `notebooks`, one row per notebook (atomic document saves; no
relational block explosion):

| column      | type               | notes                                   |
|-------------|--------------------|-----------------------------------------|
| id          | TEXT PK            | uuid v4                                 |
| title       | TEXT NOT NULL      | user-editable, default `Notebook <date>` |
| created_at  | INTEGER NOT NULL   | epoch ms                                |
| updated_at  | INTEGER NOT NULL   | epoch ms                                |
| doc_json    | TEXT NOT NULL      | ordered block list (see below)           |
| ink_json    | TEXT NOT NULL      | stroke list (see below)                  |

Migration `from < 6` creates the table only. No existing table is altered, no
existing row is touched, and `dumps` is NOT modified.

### Document JSON (`doc_json`)
```json
{"blocks": [
  {"kind": "text",     "id": "<uuid>", "text": "..."},
  {"kind": "checkbox", "id": "<uuid>", "text": "...", "checked": false},
  {"kind": "dumpCard", "id": "<uuid>", "dumpId": "<dump uuid>",
   "x": 12.0, "y": 340.0}
]}
```
- `x`/`y` are logical pixels from the canvas top-left; cards are free-dragged.
- Unknown `kind` values are preserved verbatim on load/save (forward compat).

### Ink JSON (`ink_json`)
```json
{"strokes": [
  {"id": "<uuid>", "width": 3.0,
   "points": [{"x": 1.0, "y": 2.0}, {"x": 3.0, "y": 4.0}]}
]}
```
- Ink is always white on a black canvas in phase 1; no colour picker.
- Pen width is per-stroke, captured at draw time from the toolbar slider.

### Deleted / missing dumps
A `dumpCard` whose `dumpId` no longer exists renders as a disabled placeholder
reading "Recording unavailable". It is NEVER silently dropped, and the notebook
never mutates a dump row. Embedding a dump does not move, copy, or delete it.

### Stylus vs touch
Ink strokes are accepted from stylus input (`PointerDeviceKind.stylus`) and from
touch ONLY while the toolbar's draw mode is active — so finger-scrolling a
notebook never paints. Palm rejection beyond this is out of scope.

### Entry point
Top-menu (app bar) item on the home screen opens the notebook LIST; the list
opens/creates individual notebooks. Explicit SAVE, consistent with Text Note.

## Task decomposition (3 parallel workers, disjoint file ownership)

1. **Data layer** — schema v6 + `notebooks` table + typed document/ink
   codecs + repository + Riverpod providers. Owns `client/lib/data/**` and
   `client/lib/models/notebook*`.
2. **Ink canvas widget** — self-contained `NotebookInkCanvas` widget + pen-size
   toolbar control. Owns `client/lib/widgets/notebook_ink_canvas.dart`. No
   screen or DB integration.
3. **Dump card picker + draggable card** — multi-select dump picker sheet and
   the draggable `DumpCard` widget. Owns
   `client/lib/widgets/notebook_dump_card.dart` and the picker file.

The orchestrator then integrates 1–3 into the notebook list + editor screens
and wires the home-screen menu entry.
