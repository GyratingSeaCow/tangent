# Durable Transcription State and List Markers

**Date:** 2026-09-14  
**Status:** Approved for implementation  
**Scope:** Flutter client, Tangent server job API, SQLite migrations, and physical Android verification

## Problem

Tangent currently treats server transcription progress as in-memory coordinator state. The Dumps list only shows an active in-memory operation and otherwise falls back to the unrelated cloud-sync badge. This creates two user-facing failures:

1. A user cannot quickly distinguish recordings that are transcribed, not transcribed, in progress, or failed.
2. Leaving the detail route, backgrounding Tangent, or losing the client process can sever the SSE listener and erase local knowledge of an unfinished server job. The server may continue and finish, but the client does not reliably reattach or reconcile the result. A retry can enqueue a duplicate job.

The observed `test3` incident did not truncate audio: the phone and server both held the same clean 36.94-second, 201,305-byte Opus file. The server completed both attempts. The defect is durable operation ownership and recovery, not recording persistence.

## Goals

- Make transcription state obvious on every Dumps-list row.
- Preserve unfinished transcription identity and state across navigation, backgrounding, provider recreation, and process death.
- Reattach to an existing server job without uploading or enqueueing a duplicate.
- Reconcile server completion into the local database and recoverable sidecar even when the initiating screen no longer exists.
- Prevent an older attempt from overwriting a newer attempt.
- Require explicit confirmation before retranscribing a recording that already has a transcript.
- Let the user correct a completed transcript without changing or deleting its raw recording.
- Keep the server as the owner of inference; do not add an Android foreground service for v1.
- Preserve raw recordings on every failure path.

## Non-goals

- Displaying invented percentage progress when faster-whisper exposes none.
- Keeping Dart execution continuously alive while Android suspends the app.
- Maintaining full user-visible history for every transcription attempt.
- Adding server-side cancellation in this change.
- Changing Whisper model selection or transcription accuracy settings.

## Dumps-list design

Use the approved **explicit status pill** layout. Each row shows one transcript-status pill using both text and icon so meaning does not depend on color:

- `✓ Transcribed` — green; a non-empty transcript is persisted locally.
- `○ Not transcribed` — amber/neutral; no transcript and no current attempt.
- `◌ Queued` — blue; server accepted the request but has not started inference.
- `◌ Transcribing` — blue with an indeterminate activity indicator; server job is running.
- `↑ Uploading` — blue; metadata/audio or idempotent enqueue is in progress.
- `! Failed` — red; the latest attempt failed and the recording remains available.

The transcript pill is the primary trailing marker. Cloud sync/privacy state remains secondary information in the subtitle or a smaller adjacent icon; it must not be confused with transcript state.

### Independent filters

Render two independent horizontal filter rows:

1. **Mode:** All / Brain Dump / Meeting
2. **Transcript:** All / Needs transcript / In progress / Transcribed / Failed

Filters combine with logical AND and also apply to search results. Definitions:

- **Needs transcript:** `not_transcribed` only.
- **In progress:** `uploading`, `queued`, or `running`.
- **Transcribed:** `completed` with a non-empty local transcript.
- **Failed:** `failed`.

Filter selection survives detail navigation for the app process. `Awaiting` is removed because it currently reflects sync status rather than transcription status and is ambiguous.

## Client data model

Use the existing `dumps` row as the durable latest-attempt record; do not create a separate attempts table for v1. Increment the Drift schema from version 3 to version 4 and add:

- `transcription_status TEXT NOT NULL DEFAULT 'not_transcribed'`
- `transcription_request_id TEXT NULL`
- `transcription_job_id TEXT NULL`
- `transcription_attempt INTEGER NOT NULL DEFAULT 0`
- `transcription_started_at DATETIME NULL`
- `transcription_updated_at DATETIME NULL`
- `transcription_completed_at DATETIME NULL`
- `transcription_error TEXT NULL`

Allowed statuses are `not_transcribed`, `uploading`, `queued`, `running`, `completed`, and `failed`.

### Migration rules

For existing rows:

- Non-empty `transcript` → `completed`, with `transcription_completed_at = updated_at`.
- Null or blank `transcript` → `not_transcribed`.
- Existing recordings, transcripts, meeting notes, audio locators, privacy state, and sync state remain unchanged.
- Do not infer an unfinished job from the old in-memory coordinator because that state was never durable.

The generated Drift code is regenerated and committed. Fresh-schema and v3→v4 migration tests must cover every rule.

## Idempotent server contract

Extend `POST /v1/dumps/{dump_id}/transcribe` with a required client-generated `request_id` UUID/string.

Before any upload/enqueue network operation, the client:

1. Generates a new request ID.
2. Increments `transcription_attempt`.
3. Persists the request ID, `uploading` status, start/update timestamps, and clears the prior error.
4. Only then sends metadata, audio, and enqueue requests.

Extend the server `jobs` table with `request_id TEXT NOT NULL` and a unique index. Enqueue behavior is idempotent:

- A new request ID creates one job.
- Repeating the same request ID for the same dump and model returns the existing job instead of creating another.
- Reusing a request ID with a different dump or model is rejected as a conflict.

The server response returns the existing/new `job_id` and current status. This closes the crash window between server creation and local job-ID persistence: after restart, the client safely repeats the same request ID and receives the same job.

Server migrations must upgrade existing databases without deleting jobs. Legacy job rows receive deterministic unique legacy request IDs during migration.

## App-scoped coordinator

`ServerTranscriptionService` remains app-scoped and must not depend on a detail screen's lifecycle. Its authoritative state comes from SQLite, not `_queue`, `_terminal`, or a widget-local future.

### Start flow

1. Read the dump and reject a duplicate tap if its durable status is already nonterminal.
2. Persist a new request ID and `uploading` state before network I/O.
3. Idempotently create dump metadata and upload audio.
4. Enqueue using the persisted request ID.
5. Persist the returned job ID and server status.
6. Consume SSE while the app is active.
7. Persist every meaningful status transition.
8. On completion, atomically commit transcript/meeting notes as `completed` under the attempt/request guard, then generate the sidecar from that winning committed row. If the sidecar write fails, retain a durable `sidecar_sync_pending:` error marker and repair it during reconciliation; a stale attempt never writes the sidecar.
9. On a terminal failure, persist `failed` and a recoverable error; never delete audio.

### Navigation and background behavior

- Popping the detail route only disposes screen resources such as playback. It does not cancel or dispose the transcription coordinator.
- When Android backgrounds or suspends Tangent, the server continues inference.
- On app resume, provider recreation, or cold startup, query all dumps with nonterminal transcription status and reconcile each one.
- If a durable job ID exists, call `GET /v1/jobs/{job_id}` first and then reattach to SSE or polling as appropriate.
- If a request ID exists but the job ID is missing, repeat the idempotent enqueue using that request ID and persist the returned job ID.
- Reconciliation must not repeat audio upload unless the server reports that audio is absent.

### SSE and polling

- A terminal SSE event is persisted immediately.
- Clean SSE EOF before a terminal event is not success and not failure; switch to bounded polling.
- Socket errors and SSE timeouts also switch to bounded polling.
- Poll `GET /v1/jobs/{job_id}` until terminal state or the configured overall deadline.
- Map the polling response's `result_transcript` field explicitly.
- If the app is suspended, resume reconciliation when execution returns rather than pretending continuous background execution.

### Attempt ordering

Every asynchronous completion captures the local `transcription_attempt` and `request_id` it belongs to. Before writing status, transcript, notes, or errors, compare them with the current row. Ignore stale callbacks from older attempts. An old job can never overwrite a newer retry.

## Detail-screen behavior

The detail screen observes the dump row reactively:

- `not_transcribed`: show **Transcribe**.
- `uploading`, `queued`, `running`: show the existing progress panel and allow navigation away without warning that work will stop.
- Returning to the detail screen reconstructs progress from durable state and reconciliation, not from a new operation.
- `completed`: show transcript and **Done**.
- `failed`: show the stored error, state that the recording is preserved, and offer **Retry**.

Retry creates a new request ID and increments the attempt. It must not reuse a failed request ID.

### Confirmed retranscription

Pressing **Transcribe** or **Retry** for a dump with a non-empty existing
transcript opens a confirmation dialog before any durable or network change:

- **Cancel** is the default safe action and performs no database write, upload,
  enqueue, or request-ID allocation.
- **Overwrite** starts the normal durable attempt with a fresh request ID.
- The existing transcript remains visible while the replacement is uploading,
  queued, or running and remains available if that attempt fails.
- Only a successfully committed completion replaces the existing transcript.
  Existing meeting notes remain unchanged until the user explicitly regenerates
  them. The raw recording is never modified or deleted.

### Manual transcript editing

For a completed dump, render the raw transcript as an always-editable multiline
text area rather than read-only selectable text. Editing is explicit rather than
autosaved:

- **Save transcript** is enabled only when the text differs from the persisted
  transcript and no transcription attempt is in progress.
- A blank or whitespace-only transcript cannot be saved.
- Save updates only the transcript and timestamp. It preserves the completed
  status, attempt, request ID, job ID, recording, title, and existing meeting
  notes.
- The database update is a compare-and-set against the transcript, attempt, and
  nullable request ID captured when editing began. A completion or another edit
  that wins first causes the stale save to fail visibly rather than overwrite
  newer state.
- After the database update succeeds, write the latest committed row to the
  sidecar through the shared per-dump metadata serializer.
- Existing meeting notes remain unchanged after a manual correction. The user
  can select **Regenerate notes** to derive new notes from the corrected
  transcript; its existing title/transcript/attempt/request compare-and-set
  continues to reject stale generation.

## Error handling

- Audio read/upload failure: mark `failed`; preserve audio and prior transcript.
- Enqueue response lost: replay the same request ID and recover the existing server job.
- SSE disconnect: poll rather than enqueue.
- App killed after enqueue: startup reconciliation recovers by request ID/job ID.
- Server unreachable: keep durable nonterminal identity, surface connection state, and retry reconciliation later without duplicate enqueue.
- Empty completed transcript: mark `failed` with an explicit empty-transcript error unless the product later defines empty speech as a valid terminal result.
- Database persistence failure after server completion: keep the nonterminal server identity and retry the same completed job during reconciliation.
- Sidecar persistence failure after database completion: keep the completed transcript, store a `sidecar_sync_pending:` marker, and retry only the sidecar write from the winning committed row during reconciliation.

## Testing

### Client unit and migration tests

1. Fresh schema includes all durable transcription fields.
2. v3→v4 migration marks existing non-empty transcripts completed and empty transcripts not transcribed.
3. Request ID is persisted before any network call.
4. Route disposal does not cancel the service job.
5. Completion after route disposal persists and appears on re-entry.
6. Clean SSE EOF, socket failure, and timeout fall back to polling.
7. Polling maps `result_transcript` correctly.
8. Startup and lifecycle resume reattach to stored nonterminal jobs.
9. Reattachment performs no second upload or enqueue.
10. Missing job ID with a stored request ID safely repeats idempotent enqueue.
11. Duplicate taps cannot create a second request.
12. Older job completion cannot overwrite a newer attempt.
13. DB and sidecar both contain the completed transcript.
14. Canceling overwrite confirmation performs no database or network work.
15. Confirming overwrite allocates one new attempt and replaces text only after
    successful completion; existing meeting notes stay unchanged, and failure
    retains the prior transcript and recording.
16. A manual transcript edit updates database and sidecar while preserving job
    identity and meeting notes.
17. Blank edits and stale edits racing a newer attempt are rejected.

### Widget tests

Cover every list pill and both independent filter rows:

- Not transcribed
- Uploading
- Queued
- Transcribing
- Transcribed
- Failed
- Mode + transcript filter combinations
- Search constrained by both filters

Also prove that list and detail screens update automatically from SQLite after background reconciliation.

Detail widget tests also cover the overwrite confirmation's Cancel/Overwrite
branches and the multiline transcript editor's dirty, blank, saved, and stale
concurrent-attempt states.

### Server tests

1. First enqueue with a request ID creates one job.
2. Repeating the same request returns the same job.
3. Same request ID with a different dump/model returns conflict.
4. Existing database migration preserves legacy jobs and assigns unique legacy request IDs.
5. Job polling and SSE continue to expose the same job identity and standards-compliant JSON.

### Physical Android acceptance test

1. Install with `adb install -r`; do not clear app data.
2. Start transcription of a real recording.
3. Confirm its list row shows `Transcribing`.
4. Back out to the list, switch to another app long enough for the server to finish, then return.
5. Confirm no second upload or enqueue occurred.
6. Confirm the row changes to `Transcribed` and detail shows the persisted transcript.
7. Repeat while force-stopping only after the server job ID is persisted; relaunch and confirm startup reconciliation.
8. Pull the local SQLite database and verify request ID, job ID, terminal state, transcript, and attempt number.
9. Confirm the server has only one job for the request ID.
10. Confirm PID-scoped logcat has no Flutter/unhandled transcription errors.
11. On a completed recording, verify Cancel leaves the transcript unchanged and
    Overwrite replaces it only after confirmation and successful completion.
12. Correct the replacement transcript in the multiline editor, save it, reopen
    the detail screen, and verify the correction persists without altering the
    raw recording.

## Decision summary

- Use explicit status pills (approved visual Option A).
- Use two independent filter rows: Mode and Transcript.
- Use durable latest-attempt fields on `dumps` rather than a separate history table.
- Add client-generated idempotency request IDs to close enqueue crash windows.
- Reconcile on startup/resume and fall back from SSE to polling.
- Confirm every retranscription that would replace existing text, retaining the
  old text until successful completion.
- Make completed raw transcripts explicitly editable with guarded database and
  sidecar persistence; preserve meeting notes until manual regeneration.
- Do not add an Android foreground service for v1.
