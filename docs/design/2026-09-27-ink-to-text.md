# Ink to text (lasso → Convert to text) — v1.21.0

Date: 2026-09-27 · Status: approved (Jeff's picks recorded below)

## Decisions (Jeff, 2026-09-27)

- **K1 — where the text goes: (a) replace in place.** The typed text block
  appears at the lassoed ink's bbox top-left; the lassoed strokes are
  removed. **One undo restores the ink and removes the block; one redo
  re-applies both.** No per-conversion prompt.
- **K2 — recognizer path: (a) server-only TrOCR.** Same engine as
  handwriting search (trocr-base-handwritten, "base everywhere" ruling).
  No ML Kit fallback. Offline = honest failure snackbar, ink untouched.

## What the user sees

While a lasso selection containing ink is live, the lasso row (the same
row that shows lasso-delete) gains a **Convert to text** action. Tapping
it shows a brief in-progress indicator, then the handwriting is replaced
by a typed `NotebookTextBlock` at the same spot. Failures leave the page
exactly as it was.

- Selection with ink + blocks: only the INK converts; selected blocks are
  left alone (they're already typed content).
- Blocks-only selection: Convert is disabled (greyed, not hidden — dead
  live controls are the thing Jeff rejects, disabled-looking is fine).
- Server says nothing recognizable: snackbar "No text recognized", page
  unchanged.
- OCR env not installed (409): route to the SAME not-installed story the
  handwriting-search client code already handles — grep the existing ocr
  client code for the 409 detail wording BEFORE writing any new copy; do
  not reword.
- Server unreachable / non-409 error: failure snackbar, page unchanged.
  **No mutation of strokes or blocks happens before a successful
  response.**

## Server half (Ted)

New endpoint in `server/app/api/ocr.py`:

```
POST /v1/ocr/recognize            (require_auth)
body:     {"strokes": [ ...same stroke JSON shape the notebook doc syncs... ]}
response: {"lines": [{"text": str, "stroke_ids": [str], "bbox": [x0,y0,x1,y1]}]}
```

- Pipeline per request: `ink_segmentation.segment_ink(strokes)` → for each
  `Line`, `ink_render.render_line(strokes, <union of the line's word
  stroke_ids>, scale=2.0)` → `ocr_worker.run_inference(image)`.
- **Reuse the worker's persistent `--serve` child** (`run_inference`
  already does). Never spawn a second model process. Check how
  `run_inference` locks against the background indexing worker — a
  recognize call racing a backfill must serialize, not crash or
  double-start the child.
- Lines return in reading order (segment_ink already guarantees
  top-to-bottom / left-to-right — pin it at the ENDPOINT level: a test
  posts strokes in shuffled order and asserts line order by bbox).
- `bbox` per line = union of the line's word bboxes, page coordinates
  (same space the strokes came in).
- Lines whose recognized text is empty/whitespace are dropped; an
  all-empty result is `200 {"lines": []}`.
- Env not installed (`ocr_env.python_path() is None`): **409** with the
  same "not installed" detail string the client already routes — find the
  string the existing client code matches, don't invent a variant.
- Malformed strokes (not a list, stroke without points, unknown stroke id
  reachability, etc.): 422 via pydantic validation where possible.
- Child inference failure: fail loud — 502 with a clear detail
  [default: `"handwriting recognition failed"`], never a silent
  `{"lines": []}`.
- No DB writes, no change_log, no schema change. This endpoint is
  read-compute-respond.

Server sabotage (required): (a) make the endpoint ignore segment order
(shuffle lines before responding) → the order-pinning test fails, quoted;
restore → passes. (b) drop the not-installed guard → the 409 test fails.

## Client half

Files: `client/lib/widgets/notebook_ink_canvas.dart`,
`client/lib/screens/notebook/notebook_editor_screen.dart` (CRLF!), the
existing OCR settings client (grep for where `/v1/ocr/capability` is
called; add `recognize` beside it — same base-url/auth plumbing, and note
the stale-provider trap: it must ride `transcriptionClientProvider`'s
watch as fixed in 4aa91b2).

1. **Canvas API**: expose the selected strokes
   (`List<InkStroke> get selectedStrokes`) and a
   `removeSelectedStrokes(...)` that funnels through `_pushHistory` as ONE
   entry. The undo contract (K1) spans both halves — ink lives in the
   canvas's undo stack, blocks live in the editor and have NO history.
   [default mechanism]: the canvas history entry gains an optional
   external undo/redo callback pair supplied by the editor — undo of that
   entry restores the strokes AND invokes the editor callback that removes
   the text block; redo re-removes the strokes and re-inserts the block.
   Keep `_pushHistory`'s redo-clearing funnel semantics intact
   (redo re-arms undo by direct push, never via `_pushHistory`).
2. **Editor action**: "Convert to text" in the lasso row, next to
   lasso-delete, enabled only when `selectedCount > 0` (canvas ink), not
   for blocks-only catches. On tap:
   - snapshot the selected strokes (toJson — the same shape sync pushes),
   - POST recognize (progress indicator; the lasso selection stays live),
   - on success with lines: build ONE `NotebookTextBlock` (id: new uuid,
     `text` = lines joined with `\n`, `stamps: const []`, `x`/`y` = the
     recognized ink's union-bbox top-left in canonical page px), then in
     one setState: `removeSelectedStrokes` (with the block-removal
     callback registered) + insert the block + `_dirty = true` + clear
     both selection halves.
   - `[]` lines → "No text recognized" snackbar, nothing mutates.
   - 409 → existing not-installed routing. Other errors → failure
     snackbar, nothing mutates.
3. Layout: the block is positioned (`x`/`y` non-null), so it contributes
   `x + _minBlockWidth` to `_contentRightEdge` already — no layout code
   change expected; verify with an off-column conversion test.
4. Widget tests (fake recognize client via a constructor/provider seam —
   follow the `_RecordingNotebookPersistence` override pattern):
   - convert replaces ink with the block at the bbox origin,
   - **one undo restores strokes AND removes the block; redo round-trips**
     (ping-pong: undo→redo→undo),
   - failure/409/empty paths leave strokes + blocks byte-identical,
   - blocks-only selection disables the action,
   - mid-flight: back-save during a pending recognize must not crash.

Client sabotage (required, named in the handoff): (a) insert the block
but DON'T remove the ink → the replace test fails, quoted; (b) undo
restores ink but leaves the block → the ping-pong test fails.

## Proof before merge (device, real data)

Lasso a real handwritten line on the **S11 Ultra** (Jeff's cursive; the
2026-09-21 bake-off pages are the benchmark) → Convert → the typed text
appears in place. Quote the recognized string vs. what was written.
Verified live pre-arc: `GET /v1/ocr/capability` on Jeff's container =
`{"installed": true, "flavour": "gpu", "gpu_visible": false, ...}` —
installed; CPU inference path (fine, ~0.5–0.9 s/line).

## Versioning / release

Server is touched → all four version sites: `client/pubspec.yaml`
(**1.21.0+26**), `server/app/version.py`, `server/docker-compose.yml`
image tag, `server/pyproject.toml`. No DB migration, but per recipe: DB
backup before container redeploy, rebuild with the compose files Jeff's
box uses, verify `/v1/ocr/recognize` answers on the live container.
