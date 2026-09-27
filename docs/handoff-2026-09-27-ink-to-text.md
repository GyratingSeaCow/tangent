# Handoff — 2026-09-27 (v1.20.0 shipped; next: ink-to-text)

Written for the agent that picks up Tangent after this session. Read in order:
`AGENTS.md` → this file → the design doc you write for ink-to-text. Load the
Hermes skill `tangent-app-development` first; its
`references/release-state-and-sync-gotchas.md` carries the pitfalls from every
arc (CRLF files, sabotage protocol, adb quirks, Fold screens, theme colours).

## 0. State of the world (verified, not remembered)

| | |
|---|---|
| main | `66bb05b` (docs) on top of tag **`v1.20.0` @ `249c9f7`**, pushed; remote tag = main = local |
| Release run | `36317731638` for v1.20.0 was **in_progress** at handoff — check `gh run view 36317731638` and `gh release view v1.20.0 --json assets`; v1.19.0's run `36294828745` completed **success** |
| Container | `tangent-server:1.19.0` healthy on localhost:8765 (v1.20.0 was client-only). Pre-1.19 DB backup: scratch `server_pre119.db` |
| Devices | Fold (t22 SM-F971U1, 100.92.184.58:5555) · S11 Ultra (t7 SM-X930, 192.168.1.223:5555) · S10 FE (t32 SM-X520, mDNS `adb -t N`) — **all on 1.20.0** |
| Test baselines | client **`+2203 ~2`** · server **`539 passed, 3 skipped`** · analyze clean |
| Worktrees | none (all removed cleanly; `.worktrees/` may still hold Windows-locked dead dirs from older arcs — harmless) |
| Probe data | dump `probe119-d490c4d9761b` "probe es" (Spanish, 40 s) left on the server ON PURPOSE as Jeff's translation sample; a notebook titled "Recording 2026-09-25 16-09-19" was created by the v1.20.0 walk-through — Jeff may delete it |
| Temp tokens | none active (`probe-119` revoked) |

Shipped this run, all Jeff-verified or device-proven: v1.15.0 speaker naming,
v1.16.0 timestamped Markdown export, v1.17.0 speaker name map, v1.17.1 picker
fix, v1.18.0 summary-pending card, v1.19.0 translation + summary status,
v1.20.0 transcript → notebook + Regenerate-notes feedback.

## 1. How Jeff works (non-negotiable)

- **Proof, not claims.** Run the gates yourself, quote real output. Never
  report a subagent's self-summary as fact — reproduce its tally.
- **Sabotage protocol** per seam: revert the fix → watch the named test fail
  (quote it) → restore → watch it pass. "A surviving sabotage is a missing test."
- **One real-data proof on a device before tagging.** Widget tests find by
  KEY, not by visibility — v1.19.0's Retry button was invisible (theme
  `error == errorContainer`) and only a Fold screenshot caught it.
- "Go with your best answer as the default" when he's away; mark defaults
  `[default]` in the spec. Silence on a question is a signal — stop asking.
- Ask design questions in plain words about what he'll SEE, with an example
  from his own data; one question at a time in Discord.
- Discord progress pings for long builds: channel `1362610711196598445`,
  mention `<@1232922889221836832>` (`hermes send --to discord:… "…"`).
- Any gate red you can't fix in ~2 tries: stop, don't ship, leave the real
  error in Discord.

## 2. Release recipe (worked 6× this run)

1. Spec in `docs/design/YYYY-MM-DD-<name>.md` with Jeff's picks recorded;
   commit + push before dispatching.
2. Worktrees per half: `git worktree add .worktrees/<x> -b feature/<x> main`.
   Server half → **Ted** (`hermes -p ted chat --in ~ -c "<arc> server" --create-if-missing -Q -q "…"`,
   background, notify). Client half → `delegate_task` subagent(s).
   Subagents die at ~50 tool calls: give them ≤12 reads, tell them to
   **commit green work early**, and expect to bank uncommitted wip yourself
   (`git add -A client/lib && git commit -m "wip(...)"`) then re-dispatch
   with the `not_done` list as the spec. Two of three UI children this run
   truncated; the pattern recovers cleanly.
3. Your own gates on each branch (`flutter analyze`, full `flutter test` in
   background with `notify=true`, `pytest` in `server/.venv-test`), then your
   own sabotage on a seam no child proved.
4. Merge `--no-ff`, bump `client/pubspec.yaml` (now `1.20.0+25`), AGENTS.md
   "Status", CHANGELOG, tag. If server touched: DB backup (`docker cp` needs
   a `C:/` path, not `/c/`), `docker compose -f C:/…/docker-compose.yml up -d --build`,
   verify migration columns + change_log growth on the live DB.
5. Ship-only-if-green script: build APK → install per transport → push
   main + tag → Release run → next-iteration entry → handoff → skill bump →
   Discord ping.
6. `gh run watch` in background falsely "times out" at 420 s — poll
   `gh run view <id>` in a loop instead.

## 3. NEXT: ink-to-text (Jeff: "lets do ink to text")

Not yet specced. Jeff picked it over page backgrounds / calendar titling /
live transcription. Two forks were about to be asked — **ask them first**:

- **K1 — where does the text go?** (a) replace the lassoed ink in place with
  a text block at the same spot [my default], (b) insert the text block below
  and keep the ink, (c) ask each time.
- **K2 — recognizer path.** (a) server-only via the existing TrOCR container
  (works on Linux desktop too; needs the OCR env installed, else the same
  409/install-wizard story as handwriting search) [my default], (b) also try
  Android ML Kit on-device when offline.

Everything you need already exists — this is mostly plumbing:

- **Server**: `server/app/services/ink_segmentation.py::segment_ink(strokes) → list[Line]`
  (`Line{line_id, words:[Word{stroke_ids, bbox}]}`), `ink_render.py::render_line(strokes, stroke_ids, scale=2.0) → PIL.Image`,
  `ocr_worker.py::run_inference(image) → str` (TrOCR base handwritten,
  child process, CPU or CUDA). Endpoints live in `server/app/api/ocr.py`
  (`/v1/ocr/capability|install|status|index/backfill`). **New**: a
  synchronous `POST /v1/ocr/recognize` taking `{strokes:[…]}` (the lassoed
  subset, same JSON shape the notebook doc syncs) and returning
  `{lines:[{text, stroke_ids, bbox}]}`; 409 with the existing "not
  installed" detail when the env is absent (client already routes that
  wording — check `ocr` client code before rewording anything). Reuse the
  worker's child, don't spawn a second model.
- **Client**: lasso selection lives in `client/lib/widgets/notebook_ink_canvas.dart`
  (`onSelectionChanged`, selected stroke set) and the editor's
  `_lassoBlockIds` / `_lassoing` in `notebook_editor_screen.dart` (CRLF).
  The lasso action sheet is where "Convert to text" goes. Insert a
  `NotebookTextBlock` (v1.20.0 added `stamps`; leave empty) at the ink
  bbox, remove the strokes (K1=a) in ONE undoable step — check how the
  editor's undo stack treats block+stroke edits together. Text-block layout
  helper: `client/lib/services/notebook_import.dart::layoutImportedBlocks`.
- **Proof before merge**: lasso a real handwritten line on the S11 Ultra
  (Jeff's cursive; the 2026-09-21 bake-off pages are the benchmark) →
  Convert → the typed text appears; quote the recognized string vs. what
  was written. Sabotage: (a) endpoint ignores `stroke_ids` order (lines
  come back shuffled), (b) client inserts but doesn't remove ink under K1=a.
- Watch: OCR env is installed on Jeff's container (handwriting search
  works) — confirm with `GET /v1/ocr/capability` before assuming.

Also open, small, from this morning: **Regenerate notes** is the rule-based
`MeetingNotesProcessor`, not the AI summarizer; Jeff may want it routed
through the summarizer or removed — ask when convenient.

## 4. Recovery

- This session: `session_search(query='…', session_id='20260926_020631_934331')`.
- Delegation transcripts: `C:\Users\Jeff\AppData\Local\hermes\cache\delegation\live\<id>\task-0.log`
  (`deleg_d67366af` core+ui #1, `deleg_84305a6d` ui #2).
- Screenshots of the v1.20.0 Fold proof: scratch `t2n_1..11.png`.
