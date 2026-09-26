# Tap a word, hear that moment

Approved (Jeff, 2026-09-25). Word-level transcript ↔ audio sync: tap any
word to hear it, follow along with a highlight while playing, scrub a
waveform, and see per-word confidence. Timings survive transcript edits
by best-effort re-alignment.

Decisions recorded from the design dialogue:

- **Two modes, one screen** — Edit (today's editor, untouched) and Listen
  (rendered, tappable, read-only). Chosen over tap-in-editor.
- **Graceful degradation** — recordings with segment-only data get
  sentence-level tap/highlight; recordings with nothing get a
  "Re-transcribe for word timing" affordance. Nothing is ever broken.
- **Timings sync as a dump field** (`transcript_timings`) so Listen works
  offline on every device, not fetched on demand.
- **Full karaoke** — current word highlighted, auto-scroll, tap-to-jump.
- **Lead-in**: a tap seeks to `start − 0.3 s` (clamped at 0).
- **"V1 extras" pulled in** at Jeff's direction: confidence coloring,
  waveform scrubbing, re-alignment after edits.

## 1. Server

### 1.1 Word timestamps

`transcription.py` passes `word_timestamps=True` to faster-whisper. Each
segment gains `words`:

```json
{"start": 105.04, "end": 107.2, "speaker": "Speaker 1",
 "text": "I've seen that before.",
 "words": [{"w": "I've", "s": 105.04, "e": 105.31, "p": 0.98}, ...]}
```

Compact keys on purpose: an hour of speech is ~9k words ≈ 250 KB JSON,
~40 KB gzipped on the wire. Diarization is unchanged; words inherit the
segment's speaker. `p` is faster-whisper's word probability (0–1).

### 1.2 Promotion to the dump

New nullable column `dumps.transcript_timings TEXT` (JSON) and
`dumps.timings_version INTEGER` (1). On job completion the winning job's
segments+words are copied onto the dump and `updated_at` bumps so sync
carries it. On re-transcribe *start* the column is set NULL (stale
timings never outlive a replaced transcript); completion repopulates.

`PUT /v1/dumps/{id}` transcript edits do **not** touch timings — the
client re-aligns (§3.4); the server keeps the engine's ground truth.

Backfill migration: dumps whose latest completed job has segments but
the dump has no timings get them copied with `words: []` (segment-level
Listen on day one for the 81 existing recordings).

### 1.3 Sync

`transcript_timings` and `timings_version` ride in the dump sync payload
exactly like `transcript`. Older clients ignore unknown fields (already
true of the payload decoder).

## 2. Client — persistence

- Local DB migration: `dumps.transcript_timings TEXT`, `timings_version`.
- Sync engine applies both fields on pull. No separate fetch.
- Model `TranscriptTimings { segments: List<TimedSegment> }`,
  `TimedSegment { start, end, speaker?, text, words: List<TimedWord> }`,
  `TimedWord { text, start, end, confidence }`. `hasWords` derived.
- Parser is tolerant: any malformed payload → `null` timings + one log
  line; the detail screen never crashes on bad data.

## 3. Client — Listen mode

### 3.1 Mode toggle

Segmented **Edit | Listen** control above the transcript on the dump
detail screen. Edit is the existing TextField + explicit Save,
byte-for-byte unchanged. Default mode:

| timings | audio local | default |
|---|---|---|
| words or segments | yes | Listen |
| words or segments | no | Listen (with "Download audio to play") |
| none | — | Edit |

### 3.2 Rendering

Read-only rich text: words as tappable spans grouped by segment; a
speaker label at each speaker change (meetings, reusing the existing
formatter's labels). Segment-only data renders each segment as one
tappable span.

### 3.3 Tap and follow

- Tap word → `seek(max(0, word.start − 0.3 s))` then `play()`. Segment
  span → same with `segment.start`.
- `positionStream` → binary search → current word (or segment) gets the
  highlight. Auto-scroll keeps the highlight in the middle third of the
  viewport; suppressed for 3 s after any manual scroll.
- Seeks clamp to the player's duration (truncated audio).

### 3.4 Re-alignment after edits

When the dump's `transcript` differs from the timings' concatenated
text, the client aligns them once per (transcript, timings) pair with a
token-level diff (Myers on normalized tokens: lowercase, punctuation
stripped). Rules:

- Matched tokens keep their timing.
- Inserted tokens (typed by the user) are rendered but not tappable and
  never highlighted; they carry no time.
- Deleted tokens vanish; playback simply passes through their audio.
- Replaced runs (delete+insert adjacent) — the inserted words take the
  deleted run's `[start, end]` span as a single tappable block, so a
  corrected "roomy" → "Rumi" still plays the right moment.

The alignment is cached in memory keyed by content hash; never
persisted. A small caption "Timings follow your edits where words match"
appears only when the alignment contains insertions.

### 3.5 Confidence coloring

Words with `confidence < 0.5` get a subtle underline tint (theme
warning color, low alpha); `< 0.3` a stronger tint. A toggle in the
Listen header ("Show uncertain words") persists in SettingsStore,
default **on** — this is the accuracy-first story: the app points at
exactly the words worth a second listen. Segment-only data has no
confidence and shows nothing.

### 3.6 Waveform scrubbing

A waveform strip above the transcript in Listen mode, computed client
side from the local audio (decode → RMS per bucket, ~600 buckets, cached
on disk next to the audio as `<id>.peaks.json`). Drag/tap → seek; the
playhead and the current-word highlight stay in lockstep. When audio is
not local the strip shows a flat placeholder with the download
affordance. WAV and Opus both decode through the existing playback
engine's decoder (media_kit on desktop, platform decoders on Android).

## 4. Errors and edges

- No timings + no paired server → Listen shows the transcript and no
  re-transcribe button (nothing could produce timings).
- Timings present, transcript empty (user cleared it) → alignment is all
  deletions; Listen shows nothing tappable and the caption explains.
- Word gaps: position between two words highlights nothing (not the
  previous word) so silences read as silence.
- Very long transcripts (>20k words) render lazily per segment.

## 5. Tests

Server: flag pinned; words shape; promotion on completion; NULL on
re-transcribe start; edit leaves timings; backfill of segment-only dumps;
sync payload carries both fields.

Client: parser tolerance; current-word binary search (boundaries, gaps,
before-first/after-last); lead-in clamp; default-mode table (all 5
rows); auto-scroll suppression; alignment (match / insert / delete /
replace-run / empty transcript); confidence bucketing; peaks
computation on a synthetic WAV; widget tests for tap→seek+play and
highlight movement on position ticks.

Sabotage rounds after commit, against committed state, per standing
rule.

## 6. Order of work

1. Server: word timestamps + promotion + backfill + sync (tests first).
2. Client persistence + model + parser.
3. Listen mode: render, tap, karaoke, default rules.
4. Re-alignment.
5. Confidence coloring.
6. Waveform.
7. Gates, sabotage, device install ×3 + Windows + Linux, push.
