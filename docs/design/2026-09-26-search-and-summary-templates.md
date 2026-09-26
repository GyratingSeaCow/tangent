# Transcript search & summary templates (v1.13.0)

2026-09-26. Jeff's picks: search = snippets + counts + open-at-match with
next/prev (A1=a), match tap seeks playback when word timings exist (A2=y);
templates = built-in presets + one custom slot, per-recording pick with
mode-based default (B1=a), "Summarize again" on existing recordings (B2=y).

## 1. What already exists (do not rebuild)

- Client FTS5: `dumps_fts (title, transcript)` content table with triggers
  (`local_db.dart` ~1335), `watchSearchDumps(query)` rank-ordered, already
  wired to the dumps-list search bar via `searchQueryProvider`. Search
  WORKS today; it just shows bare result cards.
- Handwriting search UX (match counts, snippets, open-at-match, next/prev
  wrap) — the interaction template for this arc.
- Tap-to-hear: `transcript_timings` on every synced dump; Listen view can
  seek to any word; `TranscriptTimings.parse` + binary search exist.
- Summarizer: single hardcoded `SYSTEM_PROMPT` in
  `server/app/summarize_infer.py` (meeting-shaped), `run_inference(dump_id,
  transcript)` → `summarize_dump` persists summary + publishes to sync in
  one transaction. Presets change the PROMPT ONLY — sampling parameters
  stay the bake-off-validated constants.
- Server settings + sync: `app_settings` table server-side; dump-level
  server-owned fields ride `_publish_dump_change` (summary columns,
  timings) with the absent-vs-null client sentinel.

## 2. Arc A — transcript search depth

### A1. Result cards: snippet + match count
- `watchSearchDumps` grows a companion: `searchDumpMatches(query)` using
  FTS5 `snippet(dumps_fts, 1, '<b>', '</b>', '…', 12)` and per-row match
  counting on the TRANSCRIPT column. Title matches show the title
  highlighted instead of a transcript snippet.
- Card layout: existing card + one snippet line (matched terms bolded) +
  trailing `n matches` chip when n > 1.

### A2. Open at match
- Tapping a result opens dump detail with an initial search context
  (`query`, occurrence index 0). Detail screen highlights all transcript
  occurrences (case-insensitive, on the plain transcript text in Edit
  mode AND on word spans in Listen mode), scrolls to the current one,
  next/prev chevrons wrap (parity with handwriting search).
- When `transcript_timings.hasWords`: the current match maps to its word
  span via character-offset alignment of the transcript against the
  timing words (LCS alignment already in `transcript_alignment.dart` —
  reuse, do not reimplement); tapping the highlighted match (or the play
  affordance on the match bar) seeks playback to that word − 0.3 s, same
  clamp as Listen taps. No timings → scroll-only, affordance hidden.
- Match state is screen-local; no persistence.

### A3. Scope
- Transcript + title only (Jeff picked (a), not (c) — meeting notes and
  summaries stay out of the index this arc). FTS schema untouched.

## 3. Arc B — summary templates

### B1. Presets (server-owned constants, ids stable on the wire)
- `meeting` — the current SYSTEM_PROMPT verbatim (default for
  mode=meeting).
- `brain_dump` — overview + key points + follow-ups; no attendee/action
  framing (default for mode=brain_dump).
- `lecture` — topic outline + key concepts + terms/definitions +
  questions to review.
- `actions_only` — action items with owners, nothing else.
- `custom` — user-authored prompt text (one slot), stored server-side in
  `app_settings` as `summary_custom_prompt`; empty = slot hidden in
  pickers. The template contract (headings discipline, "None" rule,
  language-follow) is APPENDED server-side to every custom prompt so a
  careless prompt cannot break "None"/language behavior.

### B2. Selection + persistence
- New nullable dump column `summary_template` (client v19 migration +
  absent-vs-null sync sentinel, same recipe as timings). Server dumps
  table gains the same column; `_publish_dump_change` carries it.
- Effective template = dump.summary_template ?? mode default.
- API: `POST /v1/dumps/{id}/summarize` gains optional `template` (id) —
  persisted to the dump, then re-summarize with it. Invalid id → 422.
  `GET /v1/summaries/templates` lists ids + display names + whether
  custom is configured (client pickers render from this, no hardcoded
  list in the client).
- Settings additions (client): custom prompt editor (multiline, save
  explicit — Jeff's transcript-editor conventions) under AI summaries.

### B3. Summarize again (B2=y)
- Dump detail: existing summary block gains "Summarize again" →
  template picker sheet (presets + custom when configured, current
  effective template marked) → POST with chosen id → summary replaces on
  sync. Preserve-until-success: old summary stays visible until the new
  one lands (matches re-transcription UX).
- The automatic post-transcription summarize path uses the effective
  template; no behavior change for untouched dumps.

## 4. Split

- Ted (server, worktree): presets module + prompt assembly (custom
  contract suffix), `summary_template` column + migration + publish,
  summarize endpoint `template` param + templates listing endpoint,
  `summarize_dump` threading, tests incl. one asserting the meeting
  preset string is EXACTLY the former SYSTEM_PROMPT (no silent drift).
- Me (client): search cards (snippet/count), open-at-match + next/prev +
  timed-word seek, v19 migration + sync sentinel, template picker +
  Summarize again + custom prompt editor, tests throughout. TDD both
  halves; sabotage after merge, against committed state.

## 5. Out of scope

Meeting-notes/summary indexing (A1 option c), multiple custom templates,
per-template sampling parameters, voice-matched speaker naming, server-side
search API (client FTS covers all synced transcripts already).
