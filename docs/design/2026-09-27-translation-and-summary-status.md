# Translation toggle + summary status (v1.19.0)

Decided with Jeff 2026-09-26 late: **T1=b, T2=y, S1=a**.

Two independent small features that both touch server + client. Shipped as
one release because each is a single column plus one dialog.

## Part A — Translation (T1=b, T2=y)

faster-whisper already auto-detects the language and throws it away
(`transcription.py` line ~217 logs `info.language`). It also supports
`task="translate"` which emits an English transcript from any source
language. We expose both.

### Data
- Server `dumps`: `language TEXT NULL` (ISO 639-1 from Whisper, e.g. `es`),
  `translated INTEGER NOT NULL DEFAULT 0` (1 = the stored transcript is an
  English translation of the audio). Migration `_migrate_dumps_language`
  follows the `speaker_names` pattern: idempotent, republish once so
  existing devices pull the (null, 0) shape.
- Client DB v22: same two columns. **Server-authored**, both: the device
  never sets them directly (the transcription job does), so they ride the
  server-authored bypass in the sync upsert like `transcript`.
- `JobCreate.translate: bool = False`. `JobResponse` gains `language`,
  `translated`.
- Transcription service: `transcribe(audio, hotwords=, translate=False)`
  passes `task="translate" if translate else "transcribe"`; returns
  `info.language` alongside segments. Job completion writes `language`,
  `translated` on the dump in the same UPDATE as `transcript`.
  Diarisation is unaffected (runs on audio, not text).

### UX (T1=b: per-recording only, no global switch)
- First transcription is always `translate=False` (we don't know the
  language until Whisper runs).
- Once `language` is known and is **not `en`**, the recording gets a tag
  (T2=y) on the list card and the detail header: `ES` when
  `translated=0`, `ES → EN` when `translated=1`. English recordings show
  nothing (no noise on the common case).
- **Transcribe again** on a non-English recording opens the existing
  re-transcribe dialog with one extra choice: "In Spanish (original)" /
  "In English (translate)". Language name from a small ISO→name map for
  the ~20 Whisper languages people actually use; fall back to the code
  upper-cased. English recordings keep the current dialog untouched.
- The ⋮ list action "Transcribe again" goes through the same dialog.
- Summaries: the summariser reads whatever transcript is stored, so a
  translated recording gets an English summary for free. Speaker name
  map, timestamps, export all unchanged (they operate on the stored text).

### Not in scope
- Global "always translate" switch (Jeff: b, not a).
- Translating INTO anything but English (Whisper can't).
- Keeping both transcripts at once. Re-transcribing replaces, as today;
  the user can flip back with another re-transcribe.

## Part B — Summary status (S1=a)

Today the client guesses "in progress" from a local `summary_requested_at`
and gives up after 10 minutes. The server knows the truth; expose it.

### Data
- Server `dumps`: `summary_status TEXT NULL` ∈ {`queued`, `running`,
  `failed`, NULL=idle/done}, `summary_error TEXT NULL` (short human
  reason, ≤200 chars), `summary_queue_position INTEGER NULL` (1-based,
  only meaningful while `queued`). Migration `_migrate_dumps_summary_status`
  same pattern. Server-authored, all three.
- Worker: on enqueue → `queued` + positions recomputed for every queued
  dump, published. On dequeue → `running`, position NULL, published. On
  success → NULL/NULL/NULL in the same write as `summary`,
  `summarized_at` (one publish, not two). On any exception in
  `summarize_dump` → `failed` + `summary_error` = exception class + first
  line of message, published; the job is NOT retried automatically.
  The existing `return False` paths (no transcript, already running,
  missing model) become `failed` with a matching reason rather than
  silent — except "already running", which stays a no-op.
- `DumpResponse` and the sync pull carry all three.
- Client DB v22 (same bump as Part A): three columns, server-authored.

### UX
- `summaryPending` becomes: `summary_status ∈ {queued, running}` OR the
  existing local heuristic (kept as the bridge for the first seconds
  before the server's `queued` publish lands, and for offline). The
  10-minute give-up now applies only to the local heuristic; a server
  `running` never expires client-side.
- Pending card text: `queued` with position → "Queued (2nd in line)";
  `running` → the existing "Writing <Template> summary on your server…".
- `failed` → the card becomes a red line "Summary failed: <summary_error>"
  with a **Retry** button (re-runs `runSummarizeFlow` with the row's
  current template, no picker) and a Dismiss (×) that sets a local-only
  `summary_error_dismissed_at` so the line goes away until the next
  failure. The old summary body stays underneath as always.
- List pill: red "Summary failed" while `failed` and not dismissed.
- Clearing: any successful summary (status NULL, summarized_at bumps)
  clears both the card and the dismissed marker via `applyRemoteDump`.

## Release
- Client DB **v22** (one bump for both parts), server migration adds five
  columns in two steps.
- Version **1.19.0**. Container rebuild required. Pre-migration DB backup
  first, as for v1.17.0.
- Proofs required before merge:
  1. Server: a real non-English audio file through `translate=True` yields
     English text and `language != 'en'`; `translate=False` yields the
     original. (Use a short synthesized Spanish clip if no real one
     exists — `espeak-ng` or Windows SAPI can produce one.)
  2. Server: force `infer` to raise → dump ends `failed` with a reason,
     published exactly once; a following successful run clears it.
  3. Client: a row pulled with `summary_status='failed'` renders the red
     line + Retry; Retry posts; the pulled success clears it.
  4. Sabotage each: skip `task=`, skip the `failed` write, skip the
     client clear-on-success.
