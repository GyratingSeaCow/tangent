# Custom vocabulary (boost words) — v1.14.0

Decisions (Jeff, 2026-09-26): **V1=a** one global list, server setting,
synced to every device · **V2=y** the same list is fed to the summarizer ·
**V3=a** edited in client Settings → "Custom vocabulary".

## 1. Why

The #1 complaint on every ASR product's forum: proper nouns and jargon come
back wrong *every time* ("Hermays", "Cassie OS"). faster-whisper 1.2.1 (the
pinned server version) exposes two levers on `WhisperModel.transcribe`:

- `hotwords: str` — tokens injected after `<|startofprev|>` on **every
  window**, including the first, and NOT consumed by the rolling context
  (`get_prompt`: `if hotwords and not prefix`). Capped at
  `max_length // 2 - 1` = **223 tokens**, silently truncated beyond that.
- `initial_prompt: str` — only seeds the first window; later windows use the
  model's own previous output. Weaker for a term list.

**We use `hotwords`.** `initial_prompt` stays untouched (None).

Verified in the running container: `faster_whisper.__version__ == '1.2.1'`,
signature includes `hotwords`, `get_prompt` source quoted above.

## 2. Storage & shape (server)

- `app_settings['custom_vocabulary']` — one row, value is the **canonical
  comma-joined** term list (`"Hermes, CachyOS, Tangent"`). Absent row ==
  empty list. Same helpers/pattern as `summary_templates.get_custom_prompt`
  / `set_custom_prompt` (blank clears → DELETE row).
- Canonicalisation (pure function `normalize_vocabulary(text) -> list[str]`,
  in a new `server/app/vocabulary.py`):
  1. split on newline **and** comma,
  2. strip, drop empties,
  3. de-dupe **case-insensitively, first spelling wins** (`Hermes` then
     `hermes` → keep `Hermes`),
  4. reject any term > 64 chars with **422** (detail
     `"vocabulary term too long"`), reject > 200 terms with **422**
     (`"too many vocabulary terms"`). Both counts are before token budgeting.
- `hotwords_for(terms) -> str | None`: `", ".join(terms)` or None when empty.
  Truncation to the 223-token budget is faster-whisper's job (it does it
  silently); we **report** it instead of duplicating the tokenizer: the
  settings response carries `token_estimate` computed with the loaded
  model's tokenizer when available, else `len(text) // 4` heuristic, and a
  boolean `over_budget = token_estimate > 223`.

## 3. API

```
GET  /v1/transcription/vocabulary
     → 200 {"terms": [...], "text": "a, b, c", "token_estimate": 17,
            "over_budget": false}
PUT  /v1/transcription/vocabulary   {"text": "<raw user text>"}
     → 200 same shape (canonicalised) · 422 on rule-4 violations
```
Lives in `server/app/api/transcription_models.py` beside the whisper-model
routes (same router prefix, same auth dep). Blank/whitespace `text` clears.

`/v1/server/info` is **not** touched (must stay ~0.2 s).

## 4. Transcription threading

`TranscriptionService.transcribe(audio_path, *, hotwords: str | None = None)`
— new keyword, passed straight to `self._model.transcribe(..., hotwords=hotwords)`.
`job_queue.run_job_inline` reads the setting **at job run time** (not enqueue
time — a list edited while a job waits applies to that job) via
`vocabulary.load_hotwords(db)` and passes it. Log `transcription.start` gains
`hotword_terms=<count>` (count only, never the terms — they may be names).

Every existing transcribe test keeps passing unchanged (`hotwords=None`
default; `_model.transcribe` mock asserts must accept the new kwarg).

## 5. Summarizer threading (V2=y)

`summarizer_worker` line ~320 `assemble_prompt(...)` result gets a suffix
**only when the list is non-empty**:

```
\n\nPreferred spellings for names and terms that may appear in the
transcript: Hermes, CachyOS, Tangent. Use these spellings exactly.
```
Built by `vocabulary.summary_suffix(terms) -> str` (empty string when no
terms). Appended AFTER the template/custom-contract suffix so the 409
detail strings and the custom contract are untouched. Test pins that the
Meeting preset prompt is byte-identical to before when the list is empty
(extends the existing drift-guard).

## 6. Client

### 6a. Client API — `lib/services/whisper_model_client.dart`
Add `VocabularySettings{terms, text, tokenEstimate, overBudget}` +
`fetchVocabulary()` / `setVocabulary(String text)` (PUT). `fromJson` is
defensive like `SummaryTemplate.fromJson`.

### 6b. Settings editor — new `lib/screens/settings/custom_vocabulary_section.dart`
Mounted in `settings_screen.dart` directly under the Whisper-model section.
Mirrors the Arc-B custom-template editor in `ai_summaries_section.dart`
(controller + `_saved` + `_dirty` + `_busy`, explicit **Save**, no autosave):
- Multiline `TextField` keyed `vocab-editor`, hint "One term per line or
  comma-separated: names, products, jargon".
- Live line under it keyed `vocab-status`: `"<N> terms · ~<T> tokens"`;
  when `overBudget` → `"<N> terms · ~<T> tokens — over the 223-token
  budget; later terms will be ignored"` in the error colour. N/T are
  computed **client-side** from the field text with the same rules as §2
  (pure Dart `normalizeVocabulary` in `lib/services/vocabulary.dart`,
  `len ~/ 4` token heuristic) so the count updates as you type; the
  server's numbers replace them after Save.
- **Save** keyed `vocab-save`, enabled iff dirty && !busy; on success
  snackbar "Vocabulary saved" and adopt server-canonical text into the
  field. 422 → snackbar with the server detail.
- **Clear** keyed `vocab-clear` with confirm dialog (like custom template).
- Hidden entirely when the app is not paired (same gate as the whisper
  model section).
- Helper text below: "Applies to every new transcription. Use
  **Transcribe again** on older recordings to apply it."

### 6c. No client DB change. The list is server-owned and fetched live; not
cached in Drift (no schema bump, no sync field).

## 7. Tests (minimum)

Server (`server/tests/test_vocabulary.py` + touches):
- normalize: split both delimiters, strip, dedupe case-insensitively
  first-wins, empty → [], 65-char term → 422, 201 terms → 422.
- GET empty → `terms=[] text="" over_budget=false`; PUT round-trip
  canonicalises (`"b\n a,b"` → `["b","a"]`); PUT blank clears row.
- `run_job_inline` passes `hotwords="Hermes, CachyOS"` to
  `service.transcribe` when set, `None` when unset (mock assert).
- Setting edited between enqueue and run → run-time value used.
- summarizer: suffix present iff terms; Meeting prompt byte-identical with
  empty list (drift guard).
- Log line carries a count, not terms (capture structlog).

Client:
- `test/unit/services/vocabulary_test.dart`: normalize rules mirror server.
- `test/widget/settings_custom_vocabulary_test.dart`: hidden when unpaired;
  seeds from fetch; typing updates `vocab-status`; over-budget message at
  > 223 est. tokens; Save disabled until dirty, PUTs raw text, adopts
  canonical response; Clear confirm/cancel; 422 surfaces detail.

Sabotage proofs required (per verification-standard): (1) drop the
`hotwords=` kwarg in `job_queue` → threading test fails; (2) flip
first-wins to last-wins in `normalize_vocabulary` → dedupe test fails;
(3) client: make status count ignore commas → widget test fails.

## 8. Out of scope (logged, not built)

Per-folder / per-mode lists (V1=b/c), pronunciation hints, auto-harvesting
terms from corrected transcripts, `initial_prompt` styling prompts.

## 9. Release shape

Same 7 version files + CHANGELOG + `docs/next-iteration.md` §1.12. Server
container rebuild required (new route + transcribe kwarg). Client APK to all
three devices. No client DB migration.
