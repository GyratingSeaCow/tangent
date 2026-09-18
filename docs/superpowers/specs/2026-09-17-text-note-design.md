# Text Note — Design

**Date:** 2026-09-17
**Status:** Approved by Jeff (design approach A; entry point, sync, title, and durable-file decisions confirmed in chat)
**Base:** main @ f8c0d80 (post durable-transcription-recovery merge)

## Purpose

A third capture mode on the home screen — **Text Note** — that lets Jeff type a note and drop it "into the mix": the note lives in the same Dumps collection as recordings and inherits the list, search, filters, multi-select, deletion, detail editing, sync, and durable-folder machinery.

## Decisions (settled with Jeff)

1. **Entry point:** third segment in the home mode selector: `Brain Dump | Meeting | Text Note`. With Text Note selected, the center button (note icon, caption "Tap to write") opens a typing screen instead of recording. No mic use anywhere in the path.
2. **Sync:** Text Notes sync to the self-hosted server exactly like Brain Dumps (Meeting stays the only privacy-excluded mode).
3. **Title:** auto-generated (`Note 2026-09-17 05-50-12`), editable in the detail screen. The body is the note text.
4. **Durability:** notes publish a durable file pair to the current default save folder, like recordings, so they survive uninstall.

## Data model (Approach A — note is a dump; REVISED post-audit 2026-09-17)

**No schema migration.** Schema stays 5. Pre-dispatch audit proved the capture pipeline enforces `row.audioPath == binding.audio.value` (bind/commit/cleanup) and journal coherence `audioSizeBytes == stopped.sizeBytes`; relaxing columns to nullable would contradict ~10 validated invariants. Instead:

- `dumps.audioPath` holds the note's published **`.md` locator** (the primary-content component slot); `dumps.audioSizeBytes` holds the `.md` byte length. Non-null, coherent with the journal.
- New `mode` value: `text_note` (TEXT column — no schema change). UI/sync/playback branch on `mode`, never on audioPath nullness.
- Note body stored in the existing `transcript` column → FTS search works with zero new code.
- `transcriptionStatus` gains enum value `not_applicable` (terminal). Requires extending `TranscriptionStatus` + `fromWire` + every exhaustive switch, plus the status gates in `updateDumpTranscript` and `claimLocalDeletion` (audit findings).
- `durationSeconds = 0` for notes.
- The `RecordingComponent` enum stays `{audio, metadata}`; the audio slot's filename becomes **mode-aware** (`<id>.opus` for audio modes, `<id>.md` for `text_note`) across codec, capture IO, and both storage backends. Same-file identity checks keep full strength.

**Gate:** existing-row behavior byte-identical (no migration means the gate is a no-op by construction; regression suite still proves it).

## Capture flow

1. Home screen, Text Note segment selected → center button opens **NoteComposeScreen**: one always-editable multiline field, explicit **Save** and **Cancel**. Blank saves rejected (matches `title withLength(min:1)` discipline and Jeff's editable-transcript conventions). No autosave.
2. Save allocates a dump id + reservation through the existing catalog reservation path (`mode='text_note'`, no recorder): stage `<id>.md` bytes to the owned staging dir, then reuse the reservation → prepare → publish → commit → cleanup pipeline (minus recorder/opus specifics) so notes get identical crash-safe journaling, startup recovery (`recoverOwnedCaptures`), and the F2-hardened cleanup guard.
3. On success, navigate to the existing Dump detail screen (same as recording stop).

## Durable folder representation

- `<id>.md` — the note text, UTF-8.
- `<id>.meta.json` — same sidecar schema as recordings (schemaVersion 2), `audioSizeBytes` null/absent, plus the note text in `transcript`. The binding's `text` component replaces the `audio` component.
- Published via the current default storage location (SAF on Android); editing the note in detail re-publishes `.md` + sidecar through the existing manual-publication path used by transcript edits.
- Import/reindex (`recording_importer`) recognizes `.md` + sidecar pairs and restores notes idempotently; a note whose `.md` is missing behaves like a recording with missing audio (row survives, component flagged), never silent data loss.

## Sync & server

- Client `sync_engine` treats `text_note` like `brain_dump` at the DB query boundary, with one difference: **no audio upload call**. Metadata-only `DumpCreate` (server already separates metadata from the multipart audio upload, confirmed in `server/app/models.py` / `api/dumps.py`).
- Server: accept `mode='text_note'` in `DumpCreate`/`DumpPatch` validation; dumps with mode `text_note` are rejected by transcription/job endpoints with a clear error; list/get/patch/delete work unchanged. Server DB needs no schema change if `audio_*` fields are already optional server-side — verify; if not, relax.
- `transcriptionStatus='not_applicable'` is terminal: sync must not enqueue, retry, or rewrite it.

## UI

- **Home:** three-segment selector; icon + caption swap when Text Note active. Recording-specific UI (waveform, timer) never appears for notes.
- **NoteComposeScreen:** multiline field, Save/Cancel, blank rejected, back = cancel with discard-confirm if text present.
- **Detail:** for notes, hide the playback card and the Transcribe button; title edit, body edit (existing transcript editor conventions: explicit Save, preserve newer typing during pending save), and delete work unchanged.
- **Dumps list:** note rows show a note icon instead of the duration chip; search/filters/multi-select/deletion unchanged. Mode filter gains a **Text Note** chip.

## Error handling

- Blank note: rejected in UI before any reservation exists.
- Publish/commit failures: identical recoverable paths as recordings (retain staging, journal, surface recoverable error; startup recovery reconciles). The F2 rule holds: a post-commit cleanup fault never reports a saved note as failed.
- Missing durable file at read time: component flagged, row preserved.

## Testing

- **Migration:** synthetic schema-5 + preserved device DB; zero row drift; nullable relax verified.
- **Unit:** note creation (reservation → publish → commit, no recorder involvement), blank rejection, edit re-publication, deletion components (`.md` + sidecar), importer round-trip, `not_applicable` terminality.
- **Widget:** home segment behavior (no RECORD_AUDIO path), compose screen save/cancel/discard-confirm, detail hides playback/Transcribe for notes, list icon + filter chip, FTS search hit on note text.
- **Sync contract:** local server fixture proving metadata-only sync for notes (no audio POST), server accepts and round-trips `text_note`, transcription endpoint rejects.
- **Server (pytest):** model validation, endpoint acceptance/rejection paths.
- **Physical device acceptance (needs phone, ask Jeff first):** create → appears in list + folder; edit → sidecar re-published; search finds body text; delete removes row + both files; RECORD_AUDIO appop never runs during any note flow; uninstall-survival spot-check of `.md` deferred to Jeff's discretion (uninstall touches app data — never done without explicit approval).

## Out of scope

Notes/Notebooks page, stylus, checkboxes, embedding dumps (separate next-iteration item); any transcription of notes; changing Meeting privacy semantics; speed work; Bluetooth; Tailscale.
