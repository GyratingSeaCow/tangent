# Handwriting Search (Server-Side OCR) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed-text search over handwritten notebook ink — Ctrl+F-style highlight and next/prev inside a notebook, notebook-level results from the home screen — powered by TrOCR on the server, opt-in via a Settings toggle with wizard-driven install.

**Architecture:** The server already receives full notebook stroke JSON via sync. A background worker segments strokes into lines/words geometrically, renders clean line bitmaps, runs TrOCR, and writes a word-level `ink_index` (text + bbox + stroke ids). The index syncs to devices as a new sync entity; search is a local text lookup; highlighting repaints the matched strokes. The ML stack installs on demand into a persistent venv — the base container stays lean.

**Tech Stack:** Python/FastAPI + SQLite (server), transformers TrOCR (`microsoft/trocr-base-handwritten` for BOTH flavours — Task 0 ruling, Jeff: "base everywhere"; GPU flavour = same model on CUDA), Pillow for rendering, Flutter + Drift (client).

**Spec:** `docs/design/2026-09-21-handwriting-search-ocr.md` — binding. Where this plan and the spec disagree, the spec wins; update the spec first if reality forces a change.

## Global Constraints

- Feature is OFF by default; while off there are no search icons, no indexing, no model downloads (spec §1).
- Base container image must not grow: torch/transformers/weights live in `/data/ocr-env`, installed on demand (spec §3.2).
- CPU flavour AND GPU flavour = `microsoft/trocr-base-handwritten` (Task 0 ruling: base beat large on Jeff's real ink; "base everywhere"). GPU flavour differs only in torch build — RTX 50-series needs torch cu128 wheels. Pin `transformers>=4.46,<5` and include `sentencepiece` + `protobuf` (bake-off-proven; transformers 5.x breaks TrOCR tokenizer loading) (spec §3.2).
- Recognition ahead-of-time; query time is a pure text lookup (spec §2).
- OCR inference runs in a subprocess from the OCR venv, never in the server process (spec §3.2).
- Durable-format discipline: new client-side fields/tables must not change how existing entities encode (repo standing rule).
- All tests real-path and sabotage-proven both directions (repo standing rule); Flutter suite baseline +1562 with 5 pre-existing Windows failures by name (single_instance ×4, desktop_pdf_share ×1); server baseline 185 passed, 3 skipped.
- Windows dev environment: export PATH="$LOCALAPPDATA/flutter/bin:$PATH" per shell; server tests via `server/.venv-test/Scripts/python.exe -m pytest`; leave `client/{linux,windows}/flutter/generated_*` unstaged.

## File Structure

```
server/app/services/ink_segmentation.py   NEW  stroke → lines → words (pure geometry)
server/app/services/ink_render.py         NEW  word/line strokes → PIL image
server/app/services/ocr_env.py            NEW  venv install manager + progress state
server/app/services/ocr_worker.py         NEW  indexing loop + subprocess inference
server/app/ocr_infer.py                   NEW  subprocess entrypoint (runs inside ocr-env)
server/app/api/ocr.py                     NEW  /v1/ocr/* endpoints
server/app/db.py                          MOD  ink_index table + change_log wiring
server/app/api/sync.py                    MOD  ink_index entity_type in pull path
client/lib/data/local_db.dart             MOD  InkIndexEntries table, schemaVersion 15
client/lib/services/ocr_settings_client.dart NEW /v1/ocr/* client
client/lib/services/ink_search.dart       NEW  query → matches (notebook + word level)
client/lib/screens/settings/handwriting_search_section.dart NEW toggle + wizard
client/lib/screens/notebook/notebook_find_bar.dart NEW find bar + match state
client/lib/screens/notebook/notebook_editor_screen.dart MOD search icon, highlight overlay
client/lib/screens/notebook/notebook_list_screen.dart   MOD search icon, results
client/lib/widgets/notebook_ink_canvas.dart MOD highlightedStrokeIds paint pass
```

---

### Task 0: Bake-off spike — model choice gate (GATE, run before Tasks 2–3 land flavour defaults)

**Files:**
- Create: `server/tools/ocr_bakeoff.py` (throwaway-quality allowed, committed for reproducibility)

**Interfaces:**
- Produces: a decision — which model each flavour uses. Plan defaults (base/large) stand unless Jeff's reading of the transcriptions overturns them (spec §5).

- [ ] **Step 1: Export real handwriting.** Pull 5–8 real notebook docs from Jeff's server DB (`docker exec tangent-server sqlite3 /data/tangent.db "SELECT doc FROM notebooks WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 8"`). Choose pages with cursive-leaning content.
- [ ] **Step 2: Write the spike script.** `ocr_bakeoff.py`: parse stroke JSON, naive line clustering (y-overlap), render lines at 2× to PNG (white bg, black 3px polylines), run `microsoft/trocr-base-handwritten` and `microsoft/trocr-large-handwritten` over each line via transformers pipeline, emit side-by-side markdown (`line image path | base output | large output`).
- [ ] **Step 3: Run on CPU (both models) and on the RTX 5070 (large)**, record per-line latency in the markdown.
- [ ] **Step 4: Jeff reads the transcriptions and rules.** If both flavours disappoint on cursive → STOP; escalate to spec §5's VLM path before implementing Tasks 2–7's model wiring.
- [ ] **Step 5: Commit** `server/tools/ocr_bakeoff.py` + the results markdown under `docs/design/2026-09-21-ocr-bakeoff-results.md`.

### Task 1: Server — stroke segmentation + line rendering (pure Python, no ML)

**Files:**
- Create: `server/app/services/ink_segmentation.py`, `server/app/services/ink_render.py`
- Test: `server/tests/test_ink_segmentation.py`, `server/tests/test_ink_render.py`

**Interfaces:**
- Consumes: notebook `doc` JSON — `{"ink": {"strokes": [{"id": str, "width": float, "tool": "pen"|"highlighter", "points": [{"x": f, "y": f}, ...]}, ...]}}`. Highlighter strokes are EXCLUDED from recognition (they are emphasis, not writing).
- Produces:
  - `segment_ink(strokes: list[dict]) -> list[Line]` where `Line = dataclass(line_id: str, words: list[Word])`, `Word = dataclass(stroke_ids: list[str], bbox: tuple[float, float, float, float])`. `line_id` is deterministic: sha1 of sorted member stroke ids (stable across re-runs → stable invalidation).
  - `render_line(strokes: list[dict], stroke_ids: list[str], scale: float = 2.0) -> PIL.Image` — white background, black polylines at stroke width × scale, 16px margin, capped at 384px height (TrOCR input norm).

- [ ] **Step 1: Write failing segmentation tests.** Fixtures are synthetic but geometric-realistic: (a) two words on one line separated by a gap > 1.5× median stroke height cluster into 2 Words, 1 Line; (b) two lines at distinct y-bands cluster into 2 Lines; (c) a highlighter stroke overlapping a word is excluded from every Word's stroke_ids; (d) single dot stroke → one 1-stroke Word; (e) `line_id` is identical across two calls with shuffled stroke order.

```python
def test_word_gap_splits_words():
    strokes = _word_at(x=0) + _word_at(x=200)   # helpers build multi-stroke words, height ~40
    lines = segment_ink(strokes)
    assert len(lines) == 1 and len(lines[0].words) == 2

def test_line_id_stable_under_stroke_order():
    strokes = _word_at(x=0) + _word_at(x=200)
    a = segment_ink(strokes); b = segment_ink(list(reversed(strokes)))
    assert [l.line_id for l in a] == [l.line_id for l in b]
```

- [ ] **Step 2: Run to verify FAIL** (`ImportError`): `server/.venv-test/Scripts/python.exe -m pytest tests/test_ink_segmentation.py -v`
- [ ] **Step 3: Implement segmentation.** Algorithm (all thresholds relative to median stroke bbox height H over pen strokes): line clustering by y-interval overlap ≥ 30% or vertical gap < 0.4·H; within a line, sort stroke bboxes by x-centre and split words where horizontal gap > 0.6·H; merge overlapping bboxes first (dotting i's, crossing t's ride with their word).
- [ ] **Step 4: Verify PASS; add render tests** (image mode L, white corners, ink pixels present within declared bbox, height cap respected) and implement `ink_render.py`.
- [ ] **Step 5: Sabotage-prove both directions** — break the word-gap threshold (0.6 → 6.0): gap test fails; restore: green. Break exclusion of highlighter: test (c) fails; restore.
- [ ] **Step 6: Full server suite** (expect 185+new passed), commit `feat(server): geometric ink segmentation and line rendering for OCR`.

### Task 2: Server — OCR environment install manager

**Files:**
- Create: `server/app/services/ocr_env.py`, `server/app/api/ocr.py` (capability/install/progress/uninstall only; index endpoints come in Task 3)
- Modify: `server/app/main.py` (mount router)
- Test: `server/tests/test_ocr_env.py`

**Interfaces:**
- Produces (consumed by Task 3 worker and Task 5 wizard):
  - `GET /v1/ocr/capability` → `{"installed": bool, "flavour": "gpu"|"cpu"|null, "gpu_visible": bool, "disk_free_bytes": int, "install_running": bool}`
  - `POST /v1/ocr/install {"flavour": "gpu"|"cpu"}` → 202 (409 if running)
  - `GET /v1/ocr/install/progress` → `{"phase": "venv"|"torch"|"transformers"|"weights"|"verify"|"done"|"failed", "percent": int, "detail": str}`
  - `POST /v1/ocr/uninstall` → 200; deletes venv+weights, drops ink_index rows
  - `ocr_env.python_path() -> str | None` — the venv's python if installed+verified, else None.
- All endpoints require auth (existing `require_auth` dependency).

- [ ] **Step 1: Failing tests with a faked runner.** `ocr_env.install(flavour, runner=fake)` where `runner` executes pip/download steps: assert phase sequence, percent monotonicity, atomic install (fail during "torch" → no `/data/ocr-env` dir, progress "failed" with detail), 409 on concurrent install, capability truth table (no dir → installed False; dir + verify marker → True).
- [ ] **Step 2: Run FAIL, then implement.** Install into `/data/ocr-env.tmp` → atomic rename on verified success. Steps: `python -m venv`, pip install torch (flavour-dependent index-url: cu128 line for gpu, cpu wheel otherwise), transformers+pillow, `huggingface_hub.snapshot_download` of the flavour's model into `/data/ocr-env/models/`, verify by running `ocr_infer.py --selftest` (Task 3 file; for this task the verify hook is injectable and faked). GPU visibility probe: run `nvidia-smi -L` inside container, non-zero → False.
- [ ] **Step 3: PASS; sabotage** — remove atomic rename (write in place): the fail-during-torch test dies (leftover dir); restore. Fake a second install while running: 409 test.
- [ ] **Step 4: Full server suite, commit** `feat(server): on-demand OCR environment installer with progress`.

### Task 3: Server — index schema, OCR worker, sync of ink_index

**Files:**
- Create: `server/app/services/ocr_worker.py`, `server/app/ocr_infer.py`
- Modify: `server/app/db.py` (table + migration), `server/app/api/sync.py` (pull-side entity), `server/app/api/ocr.py` (index status endpoint `GET /v1/ocr/status` → counts + backlog), `server/app/main.py` (start worker thread when installed)
- Test: `server/tests/test_ocr_worker.py`, `server/tests/test_sync_ink_index.py`

**Interfaces:**
- DB: `CREATE TABLE ink_index (id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, line_id TEXT NOT NULL, word_text TEXT NOT NULL, word_text_lower TEXT NOT NULL, bbox_json TEXT NOT NULL, stroke_ids_json TEXT NOT NULL, model TEXT NOT NULL, indexed_at INTEGER NOT NULL)` + index on `(notebook_id)`, `(word_text_lower)`.
- Worker: `ocr_worker.reindex_notebook(db, notebook_id, infer=run_inference)` — segments (Task 1), diffs `line_id`s against existing rows (unchanged lines untouched — invalidation is line-granular), renders changed lines, calls `infer(image) -> str`, splits result across the line's Words by x-order, writes rows, records change_log entries (`entity_type="ink_index"`, one change per notebook batch).
- `run_inference` shells to `ocr_env.python_path() + " app/ocr_infer.py --image <tmp.png>"`; `ocr_infer.py --selftest` renders the word "test" glyph internally and asserts the model returns non-empty.
- Sync pull: `entity_type == "ink_index"` returns the notebook's full current index rows (replace-set semantics — client drops rows for that notebook and inserts; no per-row tombstones).
- Worker trigger: hooked where notebook sync-push lands (`sync.py` `_apply_document(..., "notebooks", ...)` site) via a queue; plus a backfill scan on worker start (all notebooks lacking any index row and not deleted).

- [ ] **Step 1: Failing worker tests, inference faked** (`infer=lambda img: "hello world"`): indexes a 2-word notebook into 2 rows sharing a line_id; word_text split follows x-order; editing one line's stroke re-indexes ONLY that line (other rows' `indexed_at` unchanged); per-line infer exception → that line gets an `word_text=""`/`model="error"` row, other lines index fine; deleted notebook → rows purged.
- [ ] **Step 2: FAIL → implement worker + schema + migration** (follow db.py's existing migration pattern at :302).
- [ ] **Step 3: Sync tests**: pushing a notebook change enqueues its reindex; pulling with an `ink_index` change in the log returns replace-set rows; a client that never pulls ink_index (old app) is unaffected (additive entity — verify pull with legacy entity filter still round-trips).
- [ ] **Step 4: Sabotage both directions** — (a) invalidation broken (always reindex all lines): the `indexed_at` unchanged test dies; (b) x-order split scrambled (sort by stroke id): word-order test dies. Restore each, green.
- [ ] **Step 5: Full server suite; commit** `feat(server): OCR worker, ink_index schema and sync entity`.

### Task 4: Client — index mirror, sync consumption, search service

**Files:**
- Modify: `client/lib/data/local_db.dart` (table `InkIndexEntries`, schemaVersion 14 → 15, migration), `client/lib/services/document_sync_engine.dart` (consume `ink_index` pulls, replace-set per notebook)
- Create: `client/lib/services/ink_search.dart`
- Test: `client/test/unit/services/ink_search_test.dart`, extend the existing document_sync_engine tests' file with ink_index cases

**Interfaces:**
- Drift table mirrors server columns (id, notebookId, lineId, wordText, wordTextLower, bboxJson, strokeIdsJson, model, indexedAt).
- `class InkSearch { InkSearch(this._db); Future<List<NotebookMatchSummary>> searchNotebooks(String query); Future<List<InkMatch>> searchInNotebook(String notebookId, String query); }`
  - `InkMatch = ({String lineId, String wordText, Rect bbox, List<String> strokeIds, int pageOrderKey})` — pageOrderKey = bbox top then left, so next/prev walks reading order.
  - `NotebookMatchSummary = ({String notebookId, int matchCount, String snippet})` — snippet is the matched line's words joined.
  - Matching: case-insensitive substring on `word_text_lower`; multi-word queries match consecutive words within one `line_id`.
- Typed text blocks: `searchInNotebook` ALSO scans the notebook doc's text/checkbox block contents (loaded via existing `notebook_persistence.dart` reader) and returns them as `InkMatch` with empty strokeIds and the block's bbox — one search box covers both (spec §3.3).

- [ ] **Step 1: Failing service tests** on an in-memory LocalDb: single word match; case-insensitivity; multi-word consecutive-within-line matches, non-consecutive does NOT; reading-order sort; notebook summary counts; typed-block match carries empty strokeIds.
- [ ] **Step 2: FAIL → implement table + migration + service. Drift codegen:** `dart run build_runner build --delta` in client/.
- [ ] **Step 3: Sync consumption tests**: an `ink_index` pull replaces exactly that notebook's rows (other notebooks untouched); pull for an unknown notebook inserts cleanly (index may arrive before the notebook doc — tolerate).
- [ ] **Step 4: Sabotage** — break replace-set (append instead of replace): duplicate-rows test dies; break consecutive-word check: phrase test dies. Restore each.
- [ ] **Step 5: flutter analyze clean, full suite (baseline +1562 −5 by name), commit** `feat(client): ink index mirror, sync consumption and search service`.

### Task 5: Client — Settings toggle + install wizard

**Files:**
- Create: `client/lib/services/ocr_settings_client.dart` (capability/install/progress/uninstall calls following `transcription_client.dart` conventions — same `_fetch`/ApiException pattern), `client/lib/screens/settings/handwriting_search_section.dart`
- Modify: `client/lib/screens/settings/settings_screen.dart` (mount section), settings store (persist `handwritingSearchEnabled` bool following existing SettingsStore fields)
- Test: `client/test/unit/services/ocr_settings_client_test.dart`, `client/test/widget/handwriting_search_section_test.dart`

**Interfaces:**
- Consumes Task 2 endpoints verbatim.
- Wizard flow (spec §3.3): toggle ON → `GET capability` → confirmation dialog — GPU visible: **"Are you sure you want to install the RTX 50 Series OCR ability?"** (Jeff's wording, verbatim) with size/speed note; CPU-only: CPU wording with honest slower-indexing note; gpu absent but install must proceed → CPU flavour offered. Confirm → `POST install` → progress UI polling `install/progress` every 2s while section visible + a local notification mirroring phase/percent (reuse `transcription_notifications.dart` channel pattern) → completion notification → toggle rests ON. Toggle OFF → destructive confirm (index deleted server-side) → `POST uninstall`.
- Produces: `handwritingSearchEnabledProvider` — Tasks 6 icons appear only when true AND capability.installed.

- [ ] **Step 1: Failing widget tests with a faked client**: capability gpu → RTX wording appears verbatim; capability cpu → CPU wording; progress phases render percent and detail; install failure surfaces error + retry; toggle-off confirm names index deletion; wizard cancel leaves toggle OFF and calls nothing.
- [ ] **Step 2: FAIL → implement.** Poll timer cancelled in dispose (leaked-timer guard — the pairing screen lesson).
- [ ] **Step 3: Sabotage** — swap flavour wordings: both wording tests die; remove dispose-cancel: timer test dies. Restore.
- [ ] **Step 4: analyze clean, full suite, commit** `feat(client): handwriting search toggle and install wizard`.

### Task 6: Client — find bar, ink highlight, home-screen search

**Files:**
- Create: `client/lib/screens/notebook/notebook_find_bar.dart`
- Modify: `client/lib/widgets/notebook_ink_canvas.dart` (new ctor param `highlightedStrokeIds: Set<String>` + `currentMatchStrokeIds: Set<String>` painted as translucent accent behind ink — same layer family as lasso selection; empty sets = zero cost), `client/lib/screens/notebook/notebook_editor_screen.dart` (search icon in top bar → find bar; match state; scroll-to-bbox via existing scroll controller; deep-link param `initialFindQuery`), `client/lib/screens/notebook/notebook_list_screen.dart` (search icon → query field; result rows show matchCount + snippet; tap → editor with `initialFindQuery`)
- Test: `client/test/widget/notebook_find_bar_test.dart`, extend notebook_editor_screen_test.dart and notebook list tests

**Interfaces:**
- Consumes `InkSearch` (Task 4) and `handwritingSearchEnabledProvider` (Task 5).
- Find bar: text field, "n/m" position, prev/next buttons (`notebook-find-prev`/`-next` keys), close. Current match distinct from other matches (two stroke-id sets to the canvas).
- Editor deep-link: `NotebookEditorScreen(initialFindQuery: q)` opens with find bar populated, first match current, scrolled into view (spec: home-screen tap = "top of the ctrl+f results", next works normally).

- [ ] **Step 1: Failing widget tests** with seeded index rows in the in-memory db: typing a query highlights matching strokes (canvas receives exactly the matched ids); next advances current match in reading order and wraps; count reads "2/5"; close clears highlights; icons absent entirely when the feature toggle is off; list screen filters to matching notebooks and tap navigates carrying initialFindQuery; typed-text-block match scrolls without stroke highlight.
- [ ] **Step 2: FAIL → implement.** Canvas change is paint-only (no hit-test impact); follow the hover-ring painter pattern for the overlay layer.
- [ ] **Step 3: Sabotage** — feed all-match ids as current-match ids: the distinct-current test dies; break reading-order (sort by lineId string): order test dies; drop the toggle gate: icon-absent test dies. Restore each.
- [ ] **Step 4: analyze clean, full suite, commit** `feat(client): handwriting find bar, ink highlighting and home search`.

### Task 7: Ship — E2E on Jeff's stack, gates, release

**Files:**
- Modify: `CHANGELOG.md`, `docs/next-iteration.md`, version sites ×4 (v1.7.0 — feature release)

**Interfaces:** none new — this task proves the others.

- [ ] **Step 1: Full gates on merged main** — server pytest, flutter analyze, full flutter test with the 5 by name.
- [ ] **Step 2: GPU passthrough on Jeff's box** — compose override for NVIDIA runtime, `docker compose up -d`, verify `GET /v1/ocr/capability` reports `gpu_visible: true`.
- [ ] **Step 3: Real E2E** — enable toggle on the Fold: RTX confirmation wording appears; install runs to completion notification; backfill indexes Jeff's existing notebooks (watch `/v1/ocr/status`); search a word Jeff actually wrote from (a) home screen (deep-links to highlighted match), (b) inside the notebook (next/prev walk), (c) the Linux desktop AppImage (index synced, search works, no recognizer present).
- [ ] **Step 4: Release track** — version bump, changelog, `flutter build apk --release`, apksigner DN check, RecordingService idle check, install ×3 devices, push, tag `v1.7.0`, CI + Release workflows green, container rebuild.
- [ ] **Step 5: Update** `docs/next-iteration.md` (arc logged) and the tangent-app-development skill (new reference: OCR/search subsystem — files, endpoints, invalidation rule, wizard flow).

## Self-Review (done at write time)

1. **Spec coverage**: §1 UX → Tasks 5/6; §2 decisions table → Tasks 0/2/3/4; §3.1 index → Task 3/4; §3.2 installer+caveat → Task 2 + Task 7 Step 2; §3.3 client → Tasks 5/6; §3.4 backfill → Task 3 worker-start scan + Task 7 E2E; §4 errors → Tasks 2 (atomic/409), 3 (per-line error rows), 5 (failure UI); §5 testing incl. bake-off → Task 0 + per-task sabotage; §6 exclusions respected (no convert-to-text, English-only). No gaps found.
2. **Placeholder scan**: no TBD/TODO/"handle edge cases" steps; every test step names concrete assertions.
3. **Type consistency**: `Line/Word` (Task 1) consumed by Task 3 worker; endpoint shapes (Task 2) consumed verbatim by Task 5 client; `InkMatch`/`NotebookMatchSummary` (Task 4) consumed by Task 6; `initialFindQuery` produced/consumed within Task 6. `line_id` sha1 rule stated once (Task 1) and relied on for invalidation (Task 3) — consistent.
