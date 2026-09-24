# AI Summaries — opt-in server-side meeting/dump summarization

Status: DRAFT (spec agreed with Jeff 2026-09-24; model ruled: Qwen 3 4B
Instruct 2507). Mirrors the handwriting-search OCR arc's install/toggle
pattern (`docs/design/2026-09-21-handwriting-search-ocr.md`) — deviations
from that pattern must be called out explicitly.

## 1. What it is

After a meeting recording is transcribed and diarized, the server generates a
structured summary with a local LLM and stores it alongside the transcript.
Fully self-hosted — no cloud, no metering, in keeping with the rest of
Tangent. The feature is OFF by default and gated behind a Settings toggle
with an install wizard, exactly like handwriting search.

Summary format (appended below the speaker digest in meeting notes, and
synced to all devices):

```
## Summary
<2-5 sentence overview>

## Key decisions
- ...   (omit section if none — never fabricate)

## Action items
- <who>: <what>   (attribute only to names/speakers present in transcript)

## Open questions
- ...   (omit section if none)
```

## 2. Model & engine (RULED)

- **Model: Qwen 3 4B Instruct 2507, Q4_K_M GGUF (~2.3 GB).** Jeff's call
  after reviewing the field benchmarks: best coverage + faithfulness in its
  class (captured exact prices/dates/named owners in production benches;
  spot-checks against transcripts all true). Gemma 4 E4B was the runner-up
  (cleaner but terse, under-extracts). Do not re-litigate; a future model
  swap is a Settings-invisible server change since output format is pinned
  by prompt.
- **Engine: llama.cpp** (`llama-cpp-python` in the summarizer env), CUDA
  when available with CPU fallback — same accuracy, slower, matching the
  whisper/TrOCR precedent. Same GPU probe philosophy as whisper: probe,
  degrade gracefully, `TANGENT_SUMMARIZER_DEVICE` env override.
- **Prompt discipline (from the field benches, binding):** Qwen 4B leans on
  few-shot examples — the production bench that made it win used explicit
  format examples in the system prompt (4/4 language-lock WITH examples;
  removing them hurt it). So: rules + one worked example. Explicit
  "extract exhaustively; only include items explicitly discussed; never
  invent names, numbers, or dates" instruction (counters small-model
  under/over-extraction). Output language must follow the transcript's
  language.

## 3. Server side

Mirror of the OCR install manager, worker, and API — reuse the patterns,
not the code paths:

- **Env install**: `summarizer-env` under the data dir. Atomic
  `<base>/summarizer-env.tmp` → rename on verified success. Progress phases
  `idle|venv|runtime|weights|verify|done|failed`. 409 on concurrent
  install. Model GGUF downloaded into the env. Install verify hook =
  one-line real inference (`--selftest`).
- **Storage-walk exclusion (learned the hard way)**: `summarizer-env` /
  `summarizer-env.tmp` must be added to the anchored prune list in
  storage.py the SAME commit that creates the env, with the scandir-count
  test extended. The OCR arc shipped this bug; do not reship it.
- **Inference isolation**: llama-cpp never imported in the server process.
  Persistent `summarize_infer.py --serve` child (load model once,
  request-per-line stdin/stdout JSON), per-request deadline, restart-once,
  killed by stop. Single-flight queue — summarization jobs serialize.
- **Trigger**: after transcription+diarization complete for a meeting-mode
  dump, if capability installed AND toggle enabled, enqueue summarize.
  Manual regenerate endpoint for re-runs (idempotent, replaces).
- **Schema**: `dumps.summary` (markdown, nullable) + `dumps.summary_model`
  + `dumps.summarized_at`. Sync: absence-is-not-an-eraser (an older
  client's dump push without summary fields must not wipe them) — same
  rule as notebooks.ink.
- **API**: `/v1/summaries/settings` (capability GET / toggle POST),
  `/v1/summaries/install` (POST, 409-attach), `/v1/summaries/uninstall`
  (names BOTH consequences: env deletion AND stored summaries kept —
  summaries are user data, uninstall does NOT delete them; only the
  ability to generate new ones), `/v1/dumps/{id}/summarize` (regenerate).

## 4. Client side

- Settings section below handwriting search, same wizard skeleton:
  toggle → install wizard (download size stated ~2.4 GB) → progress with
  2s poll + notification mirror (id 1003, channel
  'summary_install_progress', through the parameterized
  AndroidTranscriptionNotificationPort — no second plumbing). Wizard
  REHYDRATES from server state on section init (the OCR arc's hardest
  E2E bug — install_running=true → attach-and-poll, no install POST;
  409 = attach, never error).
- Providers follow the OCR fix: capability client watches
  `transcriptionClientProvider` (never a secure-storage latch).
- Dump detail screen renders the summary sections (they arrive inside
  meeting_notes/synced fields — rendering must handle absence).
- "Regenerate summary" action on meeting dumps (server round-trip).
- CPU/GPU wording: same accuracy claim rule as OCR — CPU is slower,
  never "less accurate".

## 5. Explicitly out of scope (v1)

- Custom templates / template picker (queued next iteration).
- Speaker naming (queued; cheap rename version is a natural rider later).
- Summaries for non-meeting dumps (regenerate endpoint accepts any dump
  with a transcript; auto-trigger is meeting-mode only).
- "Ask your notes" RAG — separate arc.

## 6. Verification standard

Full SDD: per-task gates (flutter test/analyze, server pytest), sabotage
proofs against committed state, independent scoped review, real-device
E2E on all three devices, and a real end-to-end generation on the live
container against recording `6699a249…` before the arc is called done.
Prompt-quality validation (Task 0) happens BEFORE any app code: run the
real model on real transcripts, Jeff reads the output.
