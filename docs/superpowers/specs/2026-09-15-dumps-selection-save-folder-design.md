# Dumps multi-selection and configurable default save folder

## Approval and scope

Jeff approved the following design on 2026-09-15 in the controller conversation: Samsung Files-style Dumps selection and bulk local deletion, plus Settings default save folder changes affecting new recordings only. This document captures that approval; production implementation follows written-spec review and a reviewed implementation plan. Baseline is feature/durable-transcription-recovery at ac8696a9bf399c502cedec377011b871b3440236 in ~/Documents/ADH2/.worktrees/durable-transcription-recovery.

Two independently testable features share the existing storage boundary. Implement location safety before enabling folder switching or bulk deletion. Do not resume the paused Task 7 timestamp fix. Read its diagnosis to preserve its invariants and explicitly carry its known defect as unresolved.

## 1. Dumps selection UI

- Normal taps continue opening dump detail. Long-press enters selection mode and selects the pressed eligible dump.
- In selection mode every row displays a circular selection control on the left. Tapping the row or bubble toggles selection and never navigates to detail.
- The top selection toolbar shows Cancel, selected count, Select all, and Delete. Select all toggles all eligible items in the currently presented result set; when all are selected it clears the selection. Show partial selection accessibly.
- Selection is by stable dump ID, not list index. Ordinary rebuilds and reordering preserve membership. Newly arriving records are not silently added to an existing selection.
- Select all never includes hidden records. With search active its scope is the returned results (current search limit is 100); it must not imply an unbounded match count. It includes off-screen rows within that result set, not just mounted tiles.
- Changing search text, mode filter, or transcript filter clears the selection. Remove disappeared or newly ineligible rows from selection. Prevent late search responses from restoring stale selection.
- Back or Cancel exits selection mode without deleting anything. Zero selected is valid and disables Delete.
- Uploading, queued, running, or actively syncing records cannot be deleted. Render their controls disabled with an understandable explanation. Pending sidecar publication or concurrent storage mutation must also be guarded at the data/service boundary, not just by a UI snapshot.
- Labels, selection state, disabled explanation, and touch targets must remain accessible. Verify narrow/folded phone layout alongside current two-row filters and transcription status pills.

## 2. Confirmed local deletion

- Delete first shows a confirmation with the selected item count and states that local recordings, transcripts/notes, and metadata will be removed. Server copies are not deleted and server jobs are not canceled.
- Cancel performs no filesystem, database, or network deletion. Confirm operates on the exact selection snapshot; repeated taps cannot start duplicate batches.
- Use each recording's original storage location, never the current default folder, to delete its audio and metadata. Do not touch another directory merely because it contains the same filename/ID.
- Revalidate eligibility immediately before destructive work and coordinate with transcription, sync, manual save, metadata repair and storage publication. A write already in flight must not recreate a deleted sidecar. No unguarded database-first bulk DELETE.
- Handle partial failure honestly: report deleted, failed, and skipped counts; failed items remain identifiable and retryable. Do not report success for failed audio/sidecar deletion or hide stranded files. A retry must tolerate components already absent while distinguishing permission failure from absence.
- Reuse a single guarded deletion boundary for list and existing detail deletion so neither bypasses protection.
- Refresh list and search results after successful deletion. Do not let a stale search cache display removed records indefinitely.

## 3. Settings default save folder

- Add Settings > Storage > Default save folder with the current human-readable location and a Change folder action.
- Android uses the system Storage Access Framework folder picker and persisted read/write grants, not a raw editable filesystem-path field or broad all-files permission.
- Allow user-selected writable folders rather than restricting folder names to Documents or Tangent. New explicit selections target the chosen folder itself, with no hidden extra Tangent subdirectory.
- Preserve the legacy effective directory on upgrade: a legacy Documents grant currently resolves to its Tangent child, while a legacy Tangent grant resolves directly. Do not reinterpret old Documents as a new flat recording directory.
- Validate candidate permissions and actual usable storage before atomically committing the new default. Preserve the old default and readiness on picker cancellation, validation failure, or persistence failure. Clean up only disposable validation files created by this operation.
- Persist the default across app/process restart. Newly finalized recordings store audio and metadata together in their assigned folder.
- A default change affects future recordings only. Do not move, copy, rename, delete, or silently reimport existing recordings. Preserve access grants needed for old recordings.
- Existing recordings remain playable, transcribable, editable, repairable, and deletable in their original folders after any default change and after restart. This includes pending durable metadata repairs.
- Pin a recording's storage destination before recording work starts; reject a change while recording/finalization is active. Existing asynchronous work retains its original location even if the default later changes.
- Missing/revoked permission or removed storage produces an actionable error. Never silently redirect old-recording operations or new saves into a different directory or app-private fallback. Preserve staged audio if durable persistence fails.
- A default change does not automatically adopt unrelated files in the new folder. Existing explicit recovery/import behavior must respect correct folder ownership and detect ID collisions rather than overwriting another recording.

## 4. Architecture and ownership

The existing Flutter AudioStorage interface and Kotlin MainActivity storage channel currently route read, write, delete and list operations through one globally configured tree. Merely exposing requestAccess in Settings is unsafe. Establish persisted recording-specific location identity (audio plus corresponding sidecar directory), backward-compatible legacy binding, and locator-aware operations before adding the switch UI. Keep user-visible default selection separate from record ownership.

### Controller architecture decisions after Sol source review

The controller selects additive storage catalog/binding tables (Sol option B), not rewriting existing audioPath values or inferring opaque SAF parents. The next migration is Drift v4 to v5 unless another approved migration intervenes. Preserve all existing Dumps values and sidecar schema 2. SQLite is the sole authoritative default pointer and revision; native preferences are a frozen legacy-read source only. Platform-dependent legacy resolution is resumable bootstrap outside the schema migration transaction.

Persist StorageLocation, StorageCatalogState, RecordingBinding, CaptureReservation and LocalDeletionTicket responsibilities. RecordingBinding owns an immutable RecordingKey(dumpId, incarnation), original audio locator, stable authorized directory and logical metadata filename. Directory identity uses provider authority/document identity, not URI-string prefix or display name. Legacy Documents-to-Tangent binding must be proven against the existing audio locator; inaccessible/ambiguous rows retain an unresolved, non-redirectable original anchor. Such rows never become bound to a later default and cannot be destructively operated on until resolved. An unavailable default blocks new capture, not Settings or otherwise accessible old recordings.

Default selection is candidate selection, real capability validation with uniquely owned disposable probes, then one revision-checked SQLite default transaction serialized against capture admission. Cancel never changes readiness. Old grants remain retained; never evict old grants to make a new choice succeed. Capture reserves its location before microphone work and retains staging until both durable artifacts and DB/binding commit succeed. Settled failed saves retain original recovery context without permanently blocking future folder selection; outstanding native I/O remains fenced until it actually settles.

One app-owned RecordingMutationCoordinator supplies admission/use leases and the existing per-record serialized publication lane across provider/service replacement. Admission occurs before asynchronous acceptance, read, upload, edit or playback access. Local deletion persists an exact confirmed ticket and deletion fence before file mutation; every DB claim/mutation/import/recovery path rejects fenced, retired or wrong-incarnation records without weakening its existing CAS predicates. An outer timeout never releases protection for underlying work still running. Native serialization covers outstanding workers/activity recreation. Avoid non-reentrant lock reacquisition.

LocalDeletionService performs a read-only preview and deletes only the frozen confirmed targets. Component results distinguish removed, proven absent, failed and unknown; denied enumeration is never absence. Files must be proven owned regular components, never directories or unrelated links/partial files. Retain the row and exact component retry context until both audio and metadata are confirmed gone, then atomically remove row/binding/sync-queue entries and retain a minimal retired-ID receipt without transcript/notes. Interrupted/failed deletion uses explicit user-confirmed retry, not additional automatic deletion at startup. Fences restore before import, sync or transcription recovery. Duplicate operation IDs are idempotent only for identical payloads. Detail deletion closes and awaits its own playback lease after confirmation before attempting deletion; other active use remains protected.

Default changes never trigger adoption/import, including on restart. Keep existing legacy restoration limited to its frozen original directory; recover new interrupted saves through capture reservations. Atomic insert-if-unclaimed replaces check-then-upsert for adoption/new capture. Same proven source is already-known; another source with the same ID or a retired ID is a reported conflict. Filename/metadata-ID mismatch, unsupported schema and per-file parse/access errors fail independently without overwriting artifacts or blocking the entire library. No new import-management UI is included.

The folder picker is Android-only for this scope; Windows/Linux show their existing location read-only and retain functioning filesystem storage/deletion. Playback/storage sources are platform-tagged, preserving Windows drive and UNC paths. UI consumes a live settled presented-results snapshot with scope key/generation and per-record eligibility. Search remains bounded to its existing 100 ranked candidates before filtering, but observes mutations. Late results cannot restore a prior scope's selection.

Shared interface responsibilities are fixed: StorageCatalog handles legacy bootstrap, default observation/candidate/commit and capture reservation; RecordingCoordinator owns start through stopAndPersist; RecordingAccess owns audio/playback leases and guarded serialized publication; RecordingMutationCoordinator owns admission and actual I/O lifetime; LocalDeletionService owns preview/confirmed deletion/explicit retry/eligibility; RecordingImporter owns source-bound validation/adoption and owned-capture recovery. The implementation plan must expand these into exact compiled types/signatures as one integrated contract for controller review before dispatch, not allow workers to invent incompatible APIs independently.

Assign storage/data implementation and all mechanical caller/provider adaptations to Ted first, then independent Sol static and Zoe executable backend review. Zoe implements list/settings presentation only after that foundation passes; Sol and Ted independently review integration before build acceptance. Shared AudioStorage, native channel/backend, DB/generated schema and service integration have one owner at a time. No concurrent uncoordinated edits of shared files. Sol's source evidence and adversarial verification matrix are preserved in .superpowers/sdd/2026-09-15-dumps-selection-save-folder/sol-design-review.md; the decisions above, not report proposals, are authoritative.

Preserve current durable request/attempt/job ownership, compare-and-set guards, transcript edit revisions, serialized metadata publication, nullable request handling and existing notes. Do not use this feature as a pretext to change timestamp acknowledgment semantics. If a migration is required, test preserved-schema upgrades and all existing columns, not only fresh databases.

## 5. Verification gates

1. Executable RED-to-GREEN tests for long-press, left bubbles, selection toggles, Select all/deselect, zero selected, Back/Cancel, filter/search changes, reactive reorder/removal, off-screen items and narrow layouts.
2. Real database and temporary-filesystem deletion tests: confirmation canceled, successful batch, mixed failure, missing component retry, permission failure, active-work guard, repeated taps and races with pending sidecar publication. Prove no artifact resurrection and no other recording or folder touched.
3. Folder tests: readable display, picker cancellation, inaccessible folder, failed preference commit, persisted restart, arbitrary valid name, direct chosen-folder semantics and unchanged legacy Documents/Tangent mapping.
4. Two-folder integration: create A in old folder, switch, create B in new folder, restart, then read/transcribe/edit/repair/delete synthetic A using its original folder while B is untouched. Include identical names in unrelated folder, revoked old grant and duplicate import IDs.
5. Preserve regression suite for durable transcription, manual editing, storage and metadata publication. Report known Task 7 timestamp defect separately; do not claim a full timestamp-parity pass.
6. Run complete relevant Flutter tests, flutter analyze, native storage tests/build gates and build debug APK. Independent reviews must have zero unresolved Critical/Important findings. Report actual commands, exit codes, test counts and build hash; never fabricate skipped physical coverage.
7. APK installation, live-file deletion, live default-folder changes and physical acceptance require separate explicit authorization plus backup. At this stage build and test only using disposable fixtures; do not modify phone data.

## 6. Safety exclusions

- No phone uninstall, pm clear, original recording deletion/overwrite, live-data repair or deployment.
- Protected test3 ID 1789408759010917 and D1/D2 recordings remain untouched. No retranscription of them as a test workaround.
- No server-side cancellation, server data deletion, Android foreground service, on-device Whisper restoration or server model change; model stays exactly large-v3.
- No credential extraction, global model/config change, active gateway restart or publishing.
- Persistent server bind remains ~/Documents/ADH2/server/data; never start worktree Compose against a new default data directory.
- Specialist invocations are pinned per invocation to --model gpt-6-astra --provider openai-codex --reasoning high through canonical Bot Chat, after checking the live profile roster.
