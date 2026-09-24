# AI Summaries Implementation Plan

> **For agentic workers:** Executed via subagent-driven-development. Spec:
> `docs/design/2026-09-24-ai-summaries.md` (READ FIRST — binding). The
> handwriting-search OCR arc is the canonical pattern; its code is in-repo
> and every task names the files to mirror.

**Goal:** Opt-in, self-hosted AI summaries for meeting recordings, generated server-side with Qwen 3 4B Instruct (llama.cpp), gated behind a Settings toggle + install wizard identical in shape to handwriting search.

**Architecture:** Server owns everything heavy: an installable `summarizer-env` under the data dir (llama.cpp runtime + GGUF weights), a persistent inference child speaking line-oriented JSON over stdin/stdout, a worker that auto-summarizes meeting dumps after diarization, and REST endpoints mirroring `/v1/ocr/*`. Client adds a Settings section (toggle + wizard), renders the summary, and offers regenerate.

**Tech Stack:** FastAPI + llama.cpp (`llama-cpp-python` OR standalone llama.cpp server binary — Task 1 implementer picks what works in-container, CPU-first), Qwen3-4B-Instruct-2507 Q4_K_M GGUF (bartowski mirror; official repo is 401-gated), Flutter + Riverpod + Drift.

## Global Constraints

- Model file: `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (~2.5 GB) from
  `https://huggingface.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
  (verify exact filename at install time; official Qwen repo is gated — use bartowski).
- llama-cpp/torch-class runtimes NEVER imported in the server process. Inference lives in `summarize_infer.py`, standalone in the summarizer env. (OCR precedent: `ocr_infer.py`.)
- Persistent child from day one: `summarize_infer.py --serve` (load once, JSON-per-request over stdin/stdout, per-request deadline 180s, restart-once, killed on stop). NEVER subprocess-per-request (measured 39.1s/line overhead in the OCR arc).
- `--selftest` = one real tiny inference; it is the installer's verify hook.
- CPU inference is the baseline and MUST work in the stock container; GPU (CUDA) is opportunistic with graceful fallback. Any client copy must claim IDENTICAL accuracy for CPU vs GPU (speed differs only) — spec violation otherwise, not copy polish.
- Storage walk: `summarizer-env` and `summarizer-env.tmp` added to the ANCHORED prune in `server/app/services/storage.py` in the SAME commit that creates the env; extend the existing scandir-count test.
- Summary output template (binding, byte-stable): sections `## Summary`, `## Key decisions`, `## Action items`, `## Open questions` — EMPTY SECTIONS OMITTED (post-process strips model 'None' placeholder lines; the validated model emits them).
- Prompt: system prompt with rules + ONE worked example (Qwen 4B leans on examples — validated); "extract exhaustively; only include items explicitly discussed; never invent names, numbers, or dates"; output language follows transcript. Temperature 0.2, max_tokens 1024, ctx 8192.
- Schema: `dumps.summary` TEXT NULL, `dumps.summary_model` TEXT NULL, `dumps.summarized_at` INTEGER NULL. Sync rule: absence-is-not-an-eraser (a push payload without summary fields must not clear them) — mirror `notebooks.ink` handling.
- Sync direction: summary fields flow server→client inside the existing dump entity payloads. Client never pushes summary fields.
- API: `GET/POST /v1/summaries/settings` (capability + toggle), `POST /v1/summaries/install` (409 = already running → client attaches), `POST /v1/summaries/uninstall` (deletes env, KEEPS stored summaries), `POST /v1/dumps/{id}/summarize` (regenerate, idempotent replace, 404 unknown, 409 no transcript).
- Client: notification id 1003, channel `summary_install_progress`, through the parameterized AndroidTranscriptionNotificationPort — no second plumbing. Wizard REHYDRATES from server state (install_running → attach-and-poll, no install POST; 409 = attach, never error). Providers watch `transcriptionClientProvider` — never a secure-storage latch.
- Uninstall confirm dialog names BOTH facts: env is deleted; existing summaries are kept.
- Auto-trigger: meeting-mode dumps only, after transcription+diarization complete, only when capability installed AND toggle enabled. Regenerate endpoint accepts ANY dump with a transcript.
- Verification standard: sabotage proofs only against COMMITTED state; controller re-runs gates. Baselines: server `300 passed, 3 skipped`; client full `+1675 ~1 -5` (known 5 by name) + analyze clean.

---

### Task 1: Summarizer env installer + inference script (server)

**Files:**
- Create: `server/app/services/summarizer_env.py` (mirror `server/app/services/ocr_env.py` — read it first: atomic tmp→rename, progress phases, 409 single-flight, base-dir override for tests)
- Create: `server/app/summarize_infer.py` (mirror `server/app/ocr_infer.py`: `--serve` + `--selftest` modes; standalone, runs with the env's python/runtime, never imported by the server)
- Modify: `server/app/services/storage.py` (add `summarizer-env`/`summarizer-env.tmp` to the anchored prune)
- Test: `server/tests/test_summarizer_env.py`, extend `server/tests/test_storage.py` scandir-count test

**Requirements:**
- Progress phases: `idle|venv|runtime|weights|verify|done|failed` surfaced exactly like ocr_env's progress dict (same JSON shape the wizard polls).
- Install: create env dir under `<base>/summarizer-env.tmp` → install llama-cpp runtime (implementer's choice: `llama-cpp-python` pip wheel CPU baseline; attempt CUDA variant when `probe_gpu_visible()` (reuse from ocr_env) is true, fall back to CPU on any failure) → download GGUF with size verification (>2.4 GB) → run `--selftest` (real one-line inference, assert non-empty) → atomic rename.
- Uninstall: delete env dir; MUST NOT touch `dumps.summary*` columns.
- `--serve` protocol: one JSON object per line on stdin `{"id": str, "transcript": str}` → one per line on stdout `{"id": str, "summary": str}` or `{"id": str, "error": str}`. Model loaded once at startup. `--selftest` exits 0 with non-empty output.
- The system prompt (template rules + worked example + no-invention rules per Global Constraints) lives in `summarize_infer.py` as a module constant — single source of truth.
- Post-process in `summarize_infer.py`: strip sections whose only content matches `^-?\s*None\b.*$` (case-insensitive); strip a trailing standalone heading with no body.
- Tests: fake-runtime installer tests (no real 2.5 GB download — inject a downloader/runner like ocr_env tests do), selftest-failure → phase `failed` + tmp dir removed, storage prune anchored test (nested user dir named `summarizer-env` still counted).

### Task 2: Schema + worker + API + auto-trigger (server)

**Files:**
- Modify: `server/app/db.py` (migration: 3 dump columns; follow the existing additive-column pattern)
- Modify: `server/app/api/sync.py` (dump payload includes summary fields server→client; absence-is-not-an-eraser on push apply)
- Create: `server/app/services/summarizer_worker.py` (mirror `server/app/services/ocr_worker.py`: persistent `_InferChild`, serial queue, per-request 180s deadline, restart-once, stop kills child, per-dump error rows = log warning + leave summary NULL)
- Create: `server/app/api/summaries.py` (endpoints per Global Constraints; wire into main router)
- Modify: the transcription/diarization completion path (grep `job_queue.py` for where meeting notes are finalized) to enqueue summarize when eligible
- Test: `server/tests/test_summarizer_worker.py`, `server/tests/test_summaries_api.py`, extend sync tests

**Requirements:**
- Worker consumes `{"id": dump_id, "transcript": <transcript text>}`; writes `summary`, `summary_model` (exact GGUF stem), `summarized_at` (unix); records a dump change in `change_log` in the SAME transaction so sync propagates (pattern: `ocr_worker._purge_notebook`).
- Toggle state: server-side persisted setting (mirror wherever the OCR/handwriting toggle's server state lives — grep `handwriting` in server settings storage; if the OCR toggle is client-only, store this one in the existing server settings table pattern used by `/v1/summaries/settings`).
- Regenerate endpoint: 404 unknown dump, 409 when transcript empty/None, else enqueue and return 202 with job-ish status the client can poll via the dump itself.
- Auto-trigger eligibility exactly: mode=meeting AND capability installed AND toggle enabled. Non-meeting dumps: regenerate-only.
- Absence-is-not-an-eraser test: push a dump payload WITHOUT summary keys over a summarized dump → summary intact; push WITH `"summary": null` explicitly → also intact (client never pushes summary; treat any client-sent summary keys as ignored).

### Task 3: Client mirror + Settings toggle + install wizard

**Files:**
- Modify: client Drift schema (dump table + schema bump; grep `test/unit/data/` for the OLD schema-version pins afterward — ~12 tests pin "current version", update every one)
- Modify: sync apply path (accept summary fields from pull payloads)
- Create: `client/lib/screens/settings/ai_summaries_section.dart` (mirror `handwriting_search_section.dart` — read it first; same wizard skeleton, rehydration, 409-attach, poll timer disposal, cancel-makes-no-network-call)
- Create: `client/lib/services/summaries_client.dart` (mirror `OcrSettingsClient` incl. `baseUrl`/`authorizationHeader` getters; provider watches `transcriptionClientProvider`)
- Test: widget tests mirroring the handwriting section's (rehydrate, 409-attach, cancel, notification mirror id 1003), client `summariesEnabledProvider` seeding, schema migration tests

**Requirements:**
- Install wizard copy states the ~2.5 GB download before starting. CPU/GPU wording: identical accuracy, speed differs (exact rule from Global Constraints).
- Uninstall confirm names both consequences (env deleted; existing summaries kept).
- Toggle rests OFF after an install that completes while away (OCR precedent — deliberate).
- Notification: id 1003, channel `summary_install_progress`, parameterized port, try/catch-guarded construction (R8 lesson — a notification failure must never break the section).

### Task 4: Client rendering + regenerate

**Files:**
- Modify: the dump detail screen (grep `meeting_notes` render path) to render `summary` markdown sections ABOVE/BELOW consistent with spec: summary appended below the speaker digest — render transcript first, then summary block with a subtle header
- Modify: dump actions (⋮ menu per the list-screen contract) to add "Regenerate summary" for dumps with a transcript when capability installed
- Test: widget tests — renders when present, absent-safe, regenerate action calls the client method (fake client), action hidden when capability absent

### Task 5: Container + real-stack E2E (controller-led)

- Rebuild container; real install through the API on the live server (CPU path is the container reality unless CUDA llama wheel works); verify progress phases, selftest, storage-walk timing unchanged.
- Real generation on recording `6699a249…` — Jeff reads the output.
- Toggle + wizard on the Fold; regenerate; sync to all three devices; summary renders everywhere.
- Uninstall/reinstall cycle: summaries survive uninstall.
