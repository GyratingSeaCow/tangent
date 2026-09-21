# Handwriting search (server-side OCR)

Date: 2026-09-21
Status: DRAFT — awaiting Jeff's approval
Decided in conversation with Jeff; every decision below was his call or
confirmed by him.

## 1. What this is

Typed-text search over handwritten notebook ink. A search icon in the top
toolbar of the Notebooks home screen and of the notebook editor. Results
behave like Ctrl+F in a browser:

- **Inside a notebook**: matching handwriting is visually highlighted on
  the page; next/previous controls step through matches.
- **From the home screen**: matching notebooks are listed; tapping one
  opens it in find mode at the first match, with the same next controls.

The whole feature is **opt-in and off by default** (Settings toggle).
While off: no search icons, no indexing, no model on the server.

## 2. Decisions and their reasons

| Decision | Reason |
|---|---|
| Recognition runs on the **server**, not on-device | ML Kit (the on-device option) does not exist on Linux; ink drawn on the desktop AppImage would never become searchable. Jeff: "it needs to work with linux as well." |
| Recognizer: **TrOCR handwritten** (option A) | Transformer OCR fine-tuned on the IAM handwriting corpus (heavy cursive representation — matches Jeff's "cursive tendencies"). Ships as a pip dependency like faster-whisper. |
| **CPU-first, GPU as the speed upgrade** | "Some people will not be able to run GPUs." Both flavours use `microsoft/trocr-base-handwritten` — the 2026-09-21 bake-off on Jeff's real handwriting showed base ≥ large (large added errors, fixed none; Jeff ruled "base everywhere"). The RTX flavour is the same model on CUDA: ~0.1s/line vs ~0.5–0.9s/line, i.e. fast backfill, not different weights. See `2026-09-21-ocr-bakeoff-results.md`. |
| Install is **wizard-driven from the app**, off by default | Heavy ML stacks must not ride in everyone's base container. Toggle-on walks through setup: capability detection, an explicit confirmation ("Are you sure you want to install the RTX 50 Series OCR ability?" / CPU wording on GPU-less hosts), live install progress notifications, and a completion notification. |
| **Recognition is ahead-of-time; query time is a text lookup** | Millisecond search either way; recognition latency only affects how soon fresh ink becomes searchable. |
| Index **syncs back to devices** | Query works offline everywhere; only fresh-since-last-sync ink is unsearchable until the next sync round-trip. |
| **Bake-off spike before committing** to model flavours | Accuracy on Jeff's real pages is the benchmark that matters. Export real pages, run base vs large (CPU + GPU), read the transcriptions. An hour of knowing beats guessing. |

## 3. Architecture

```
 device                          server (tangent-server container)
┌──────────────┐  existing sync  ┌──────────────────────────────────┐
│ notebook doc ├────────────────►│ notebooks table (stroke JSON)    │
│ (strokes)    │                 │        │ on change               │
└──────────────┘                 │        ▼                         │
                                 │ OCR worker (background thread)   │
                                 │  1. segment strokes into lines/  │
                                 │     words (geometric clustering) │
                                 │  2. render each line to a clean  │
                                 │     bitmap (uniform ink on white)│
                                 │  3. TrOCR recognize              │
                                 │  4. write ink_index rows         │
┌──────────────┐   index sync    │        │                         │
│ local index  │◄────────────────┤ ink_index (per word: text,       │
│ (search UI)  │                 │  bbox, stroke ids, notebook/page)│
└──────────────┘                 └──────────────────────────────────┘
```

Key advantage over photo OCR: we hold exact pen trajectories. Line/word
segmentation is geometric clustering of strokes (gap thresholds scaled by
stroke height), and the rendered line images are perfectly clean — no
lighting, skew, or background noise. TrOCR sees better input than its
training data.

### 3.1 The index

New synced entity `ink_index` (server table + client mirror):

- `notebook_id`, `word_text` (lowercased for matching; original kept),
  `bbox` (canonical page px), `stroke_ids` (the strokes that formed the
  word), `line_id` (groups words for phrase matching), `model` + `model_version`
  (so a model upgrade can re-index selectively), `indexed_at`.
- Client stores it in the existing local DB; search is a LIKE/FTS query.
- Highlighting: the matched word's `stroke_ids` are repainted with a
  translucent accent overlay (same mechanism family as lasso selection);
  `bbox` drives scroll-to-match.
- A notebook edit invalidates only the lines whose strokes changed
  (stroke ids are stable); the worker re-indexes those lines.

### 3.2 The install manager (server)

The base container stays lean. New endpoints:

- `GET /v1/ocr/capability` — reports: feature installed? GPU visible
  (`nvidia-smi` probe)? disk space? Already-running install?
- `POST /v1/ocr/install` — kicks off a background install into a
  **persistent volume** (`/data/ocr-env`): a dedicated venv, torch
  (CUDA wheel if GPU flavour — RTX 50-series/Blackwell needs the
  cu128+ wheel line, torch ≥ 2.7 — else CPU wheel), transformers,
  and the chosen TrOCR weights. Survives container recreation.
- `GET /v1/ocr/install/progress` — phase + percent + human line
  (client polls while the wizard is open; notification mirrors it).
- `POST /v1/ocr/uninstall` — toggle-off path: stop worker, delete venv +
  weights, drop index (client confirms first; index deletion is the
  destructive part and is called out in the confirm dialog).

OCR inference runs in a **subprocess** out of that venv (same isolation
pattern whisper would like to have had): a crash or OOM kills the job,
not the server.

**Honest caveat (called out in the wizard):** a container only sees the
GPU if it was *started* with GPU access. If `nvidia-smi` probes fail
inside the container but the host likely has NVIDIA hardware, the wizard
shows the one host-side step (compose override + `docker compose up -d`)
and re-probes. On Jeff's box this step is done once during implementation,
so his experience is toggle → confirm → progress → done.

### 3.3 Client

- **Settings**: "Handwriting search" section. Master toggle (off).
  Toggle-on → wizard: capability check → flavour-aware confirmation
  (RTX wording when GPU visible, CPU wording otherwise, with honest
  size/speed expectations) → progress (in-app notification, mirrored
  live in the wizard) → completion notification → indexing backfill
  begins server-side.
- **Notebooks home**: search icon in top bar (only when feature enabled).
  Query filters the list to matching notebooks with a match count and a
  snippet of recognized text; tap opens the editor in find mode.
- **Editor**: search icon in top toolbar → find bar (text field,
  match position "3/17", prev/next, close). Matches highlighted on the
  ink; current match distinguished; scroll follows next/prev.
- Search matches recognized handwriting AND typed text blocks (one search
  box; typed blocks are matched directly, no OCR involved).

### 3.4 Backfill and freshness

- On first enable, every existing notebook is queued oldest-first; the
  worker chews through in the background (progress visible in Settings).
- Steady state: a notebook is (re)indexed when its sync push lands.
  Freshness = sync latency + seconds of inference, not query time.

## 4. Error handling

- Install: disk-space precheck; download failures retry then surface in
  the wizard with the real error; a failed install leaves no half-venv
  (install into temp dir, atomic rename on success).
- Recognition: per-line failures store an empty result with an error
  mark rather than aborting the notebook; the worker never blocks sync.
- GPU OOM / driver loss: job falls back to CPU for that run and flags
  the degradation in `capability`.
- Server unreachable at query time: local index still answers; UI shows
  staleness only if the user asks (no nagging).

## 5. Testing

Per the house standard (real paths, sabotage-proven both directions):

- **Server**: segmentation unit tests on synthetic stroke fixtures
  (known word gaps); renderer golden tests; install-manager tests with a
  faked downloader (progress phases, atomic failure); index invalidation
  tests (edit one line → only that line re-indexed). TrOCR itself is
  mocked in unit tests; a marked `slow` integration test runs one real
  line through the real model.
- **Client**: find-bar widget tests (highlight overlay reads the right
  stroke ids; next/prev order; count); home search filter tests; wizard
  state tests (capability variants: GPU, CPU-only, install-in-progress,
  failure); toggle-off destroys nothing without confirmation.
- **Bake-off spike (Task 0, gate for model choice)**: render lines from
  Jeff's real notebooks; run trocr-base-handwritten (CPU) and
  trocr-large-handwritten (CPU + RTX 5070); present transcriptions
  side by side. Jeff picks by reading them. If both disappoint on
  cursive, escalate to the VLM option (Qwen2.5-VL) before building
  more — the pipeline is recognizer-agnostic by design.

## 6. Explicitly out of scope (v1)

- Recognition on the Linux desktop of locally-drawn ink → same server
  path as everything else (the desktop syncs; the server indexes).
- Handwriting-to-text conversion (select ink → get editable text) — the
  index makes this cheap later; not in v1.
- Phrase/fuzzy search beyond simple substring-across-words on `line_id`.
- Languages beyond English.
