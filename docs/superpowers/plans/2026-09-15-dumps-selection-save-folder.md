# Dumps Selection and Default Save Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Samsung Files-style selection and confirmed local deletion, and an Android default save-folder setting that never redirects existing recordings.

**Architecture:** Implement the user-approved additive v5 storage catalog/bindings, SQLite-only default authority, frozen legacy anchors, pinned capture reservations and persistent deletion tickets. One app-owned mutation coordinator owns admission and actual I/O lifetime; all consumers use bound locators and the existing guarded publication semantics. Storage/data and mechanical adaptations precede independent backend reviews, then UI and independent integration reviews.

**Tech Stack:** Existing Dart >=3.6.0 / Flutter >=3.27.0 project, Riverpod 2, Drift/SQLite/FTS5, filesystem adapters, Kotlin/Android SAF, AndroidX DocumentFile; existing flutter_test/sqlite3 and JVM JUnit tests. Adopted T5-I2 correction adds exactly crypto: 3.0.6 as a direct runtime dependency; retain JUnit 4.13.2 and add org.json:json:20240303 as Android JVM test-only dependencies (adopted T5-I2 harness amendment). No unrelated dependency upgrades.

## Global Constraints

The following project-wide constraints are copied verbatim from the approved spec. All task briefs inherit them; the controller must include this section with every dispatched brief.

Do not resume the paused Task 7 timestamp fix. Read its diagnosis to preserve its invariants and explicitly carry its known defect as unresolved.

The controller selects additive storage catalog/binding tables (Sol option B), not rewriting existing audioPath values or inferring opaque SAF parents. The next migration is Drift v4 to v5 unless another approved migration intervenes. Preserve all existing Dumps values and sidecar schema 2. SQLite is the sole authoritative default pointer and revision; native preferences are a frozen legacy-read source only. Platform-dependent legacy resolution is resumable bootstrap outside the schema migration transaction.

The folder picker is Android-only for this scope; Windows/Linux show their existing location read-only and retain functioning filesystem storage/deletion. Playback/storage sources are platform-tagged, preserving Windows drive and UNC paths. UI consumes a live settled presented-results snapshot with scope key/generation and per-record eligibility. Search remains bounded to its existing 100 ranked candidates before filtering, but observes mutations. Late results cannot restore a prior scope's selection.

Preserve current durable request/attempt/job ownership, compare-and-set guards, transcript edit revisions, serialized metadata publication, nullable request handling and existing notes. Do not use this feature as a pretext to change timestamp acknowledgment semantics. If a migration is required, test preserved-schema upgrades and all existing columns, not only fresh databases.

- No phone uninstall, pm clear, original recording deletion/overwrite, live-data repair or deployment.
- Protected test3 ID 1789408759010917 and D1/D2 recordings remain untouched. No retranscription of them as a test workaround.
- No server-side cancellation, server data deletion, Android foreground service, on-device Whisper restoration or server model change; model stays exactly large-v3.
- No credential extraction, global model/config change, active gateway restart or publishing.
- Persistent server bind remains ~/Documents/ADH2/server/data; never start worktree Compose against a new default data directory.
- Specialist invocations are pinned per invocation to --model gpt-6-astra --provider openai-codex --reasoning high through canonical Bot Chat, after checking the live profile roster.

---



**Adopted Task 4 prerequisite clarification:** `docs/superpowers/specs/2026-09-15-frozen-legacy-inspection-contract.md` is binding and must be read with every task affected by legacy inspection. `inspectLegacyStorage` is capture-only when frozenAnchorJson is null, and resolve-only against exact persisted bytes when supplied. Capture precedes provider access; SQLite freeze precedes resolution. Nullable location is intentional. Never reread preferences/current defaults to recover a frozen source. This supersedes earlier capture-and-resolve wording and expands Task 4 only by the adopted document's bounded prerequisite inventory.

**Adopted Task5 publication correction (phase-A transitional C1):** Read `docs/superpowers/specs/2026-09-15-capture-publication-handoff-contract.md` in full. It governs exact prepare/SQLite-freeze/initialize/reconcile behavior, identity ports, crypto dependency, journal/wire shapes, scoped files and test matrix. During phase A only, C1 retains legacy publishCapture alongside new primitives to remain compilable; phase B removes the legacy method and all callers atomically. Task5 is not accepted until integration and scoped review pass. Earlier one-shot publication wording is superseded. No old semantic metadata/timestamp/CAS changes or phone operations.

## Authority, execution boundary and source map

This document is a plan submitted to the controller, not authorization to execute it. During plan authorship only this file and `.superpowers/sdd/2026-09-15-dumps-selection-save-folder/plan-self-review.md` may be written. No tests, package installation, production edits, phone/server commands, deployment, commits or agent dispatch occur in this lane. Commands below are instructions for later controller-authorized disposable-fixture implementation/build lanes. No physical acceptance commands are supplied.

- Worktree: `~/Documents/ADH2/.worktrees/durable-transcription-recovery`.
- Branch: `feature/durable-transcription-recovery`.
- Reviewed planning HEAD: `3b2282338a6cbd24a9f3fbe51e0a4fc610092163`; deployment baseline: `ac8696a9bf399c502cedec377011b871b3440236`.
- Approved spec: `docs/superpowers/specs/2026-09-15-dumps-selection-save-folder-design.md`, all sections; §4 overrides proposals in the old review. No architecture choices remain open.
- Read `AGENTS.md`, the entire prior `sol-design-review.md`, `docs/superpowers/specs/2026-09-14-durable-transcription-state-design.md` and `.superpowers/sdd/2026-09-14-durable-transcription-recovery/task-7-timestamp-diagnosis.md`.
- Protected IDs, never used in test fixtures: `1789408759010917`, `1789495133804048`, `1789496792876605`.

Current source facts underlying the tasks:

| Source | Required adaptation |
|---|---|
| `client/lib/data/audio_storage.dart:60–64,71–125,134–225,228–282` | Cancel changes readiness; staging is deleted before DB commit; reads/writes/deletes/import use current root. Preserve serializer behavior, replace routing. |
| `client/android/app/src/main/kotlin/dev/tangent/tangent/MainActivity.kt:125–247,423–438` | Legacy Documents→Tangent; unchecked preference commit/delete booleans; fixed partial names; independent global-root lookups; worker threads. |
| `client/lib/data/local_db.dart:17–107,148–188,195–551` | v4 schema, eight transcription columns, FTS, unguarded row deletion/upsert, CAS methods and recovery/sync queries. |
| `client/lib/services/recording_service.dart:60–83`, `recording_persistence.dart:16–49`, `client/lib/screens/recording/recording_controller.dart:74–82`, `client/lib/screens/home/home_screen.dart:50–56` | Recorder chooses filename; stop returns idle before persistence; upsert occurs after staging removal. |
| `client/lib/services/sync_engine.dart:57–96` | Reads/uploads before `syncing`; empty-byte fallback hides read errors. |
| `client/lib/services/server_transcription_service.dart:326,483–484,606–703,729–793,915–983` | Acceptance, input reads, bounded outer sidecar wait, normal/recovery publication and exact ownership guards. |
| `client/lib/data/manual_transcript_publication.dart:12–60`, `client/lib/screens/dump/dump_detail_screen.dart:94–120,149–238,310–387` | One-use manual revision, generic edits, player lifetime and existing unguarded detail delete. |
| `client/lib/screens/home/home_providers.dart:29–57,120–133`, `client/lib/main.dart:42–72,146–181` | App-scoped repair owner, replaceable services, startup import and readiness routing. |
| `client/lib/screens/dump/dumps_providers.dart:61–85`, `client/lib/data/local_db.dart:175–188` | Watched normal list, non-watched capped FTS search. |
| `client/lib/services/recording_playback.dart:26–36,62–67,83–115`, `client/lib/screens/settings/settings_screen.dart` | Typed playback source and awaitable close; Storage settings independent of server configuration. |

## Deliverables, dependencies and ownership

There are **eight substantive implementation tasks** and **three named gates**. Each task contains smaller RED/GREEN/refactor/commit cycles. Do not treat all Ted work as one unreviewable change.

| Task | Owner | Depends on | Independently reviewable output |
|---|---|---|---|
| 1. Contract, v5 schema and migration | Ted | Controller verifies this plan | Shared types/codecs and additive migration with synthetic old-schema preservation. |
| 2. Locator-aware filesystem and native SAF backend | Ted | 1 | Real explicit-root I/O, truthful outcomes, JVM-tested native policy and actual-worker lifetime. |
| 3. Shared admission, publication and retirement primitives | Ted | 1, 2 | App-owned leases/FIFO and guarded DB claim/finalize primitives. |
| 4. Legacy bootstrap and transactional default catalog | Ted | 1–3 | Stable legacy binding, candidate validation and revision-checked default, no import on switch. |
| 5. Pinned capture and collision-safe import | Ted | 1–4 | Reservation-to-publication-to-row lifecycle, staging retention, scoped restoration. |
| 6. Local deletion, reactive queries and all mechanical callers | Ted | 1–5 | Recoverable bulk/detail service, every producer guarded, application composition and live result source. |
| Backend gate B | Sol static + Zoe independent executable | 1–6 | Both review reports pass with zero unresolved new Critical/Important findings. |
| 7. Dumps selection and confirmed-result UI | Zoe | B | Accessible selection, exact confirmation/retry, current-scope results. |
| 8. Settings Storage UI | Zoe | B, 7 | Android-only candidate/commit UX; unchanged old-file access and desktop behavior. |
| Integration gate I | Sol static + Ted independent executable | 7, 8 | Cross-feature behavior, old invariant preservation and scope pass. |
| Build gate G | Zoe produces artifacts; Ted verifies results; controller accepts | I | Real full Flutter tests/analyzer, native unit tests/lint and debug APK/hash. |

No parallel edits to shared files. Ted owns all new `client/lib/data/storage/` files, `audio_storage.dart`, `local_db.dart`, `local_db.g.dart`, native storage code, recorder/persistence/import/deletion services and mechanical provider/caller/test adaptations through task 6. Zoe then owns list/detail presentation and Settings. A backend defect found by Zoe goes back to Ted before the backend gate; a UI defect found by Ted goes back to Zoe. Reviewers do not self-approve their implementation.

The controller sends each task its complete brief, Global Constraints, its verbatim contract capsule below, prerequisite commit IDs, referenced fixture files and immutable reviewed base. The repeated capsules are copies of ONE contract; any revision requires changing the canonical block and every copy together before dispatch.

## Canonical contract C1

Create `client/lib/data/storage/storage_contract.dart` from this block. Records provide value equality for keys. Boundary functions validate tagged-record invariants; empty unused locator fields are deliberate wire encoding, not permission to infer locations. `DirectoryRef.kind` is exactly `file` or `saf`; a file root has only an absolute `path`, and a SAF root has empty `path` plus nonempty `authority`, `treeUri` and effective `documentId`. `AudioLocator.kind` is exactly `file` or `saf`; never classify Windows paths with `Uri.hasScheme`.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

### Construction ABI and files

These are exact constructors to implement, not extra architecture options. Every constructor argument is defined by C1 or the existing imported `LocalDb`, `RecordingService`, `RecordingPlaybackEngine` types. Public service results use C1; helpers remain private to their implementation file.

| File | Exact constructor |
|---|---|
| `client/lib/data/storage/filesystem_storage_backend.dart` | `FilesystemStorageBackend()` implements `StorageBackend`; use an ordinary extendible `class` for the scripted test backend, not `final`/`base`; has no current-root property. |
| `client/lib/data/storage/saf_storage_backend.dart` | `SafStorageBackend({MethodChannel channel = const MethodChannel('dev.tangent.tangent/storage')})` implements `StorageBackend`. |
| `client/lib/data/storage/recording_mutation_coordinator.dart` | `DefaultRecordingMutationCoordinator({required LocalDb db})` implements `RecordingMutationCoordinator`. |
| `client/lib/data/storage/storage_catalog.dart` | `SqliteStorageCatalog({required LocalDb db, required StorageBackend backend, required RecordingMutationCoordinator mutations, required String stagingDirectory, required String Function() idFactory, required DateTime Function() now, required bool canChooseDefault})` implements `StorageCatalog`. |
| `client/lib/data/storage/recording_access.dart` | `BoundRecordingAccess({required LocalDb db, required StorageBackend backend, required RecordingMutationCoordinator mutations})` implements `RecordingAccess`. |
| `client/lib/services/recording_coordinator.dart` | `DefaultRecordingCoordinator({required LocalDb db, required StorageCatalog catalog, required StorageBackend backend, required RecordingMutationCoordinator mutations, required RecordingService recorder, required DateTime Function() now})` implements `RecordingCoordinator`. |
| `client/lib/data/storage/recording_importer.dart` | `BoundRecordingImporter({required LocalDb db, required StorageBackend backend, required RecordingMutationCoordinator mutations})` implements `RecordingImporter`. |
| `client/lib/data/storage/local_deletion_service.dart` | `DefaultLocalDeletionService({required LocalDb db, required StorageBackend backend, required RecordingMutationCoordinator mutations})` implements `LocalDeletionService`. |

`StorageFault` is the only expected thrown boundary exception and carries `StorageProblem`. Failed `Outcome` values represent normal domain rejection. Preserve stack traces for unexpected faults; no `catch` may convert permission failure into absence. No service takes a server-delete/cancel dependency.

### Database ABI and storage encoding

Add `client/lib/data/storage/storage_tables.dart`, register its Drift tables in `LocalDb`, regenerate `local_db.g.dart`. Use normal Drift columns and indexes rather than loading platform APIs during migration. Tables/column names are fixed:

- `storage_locations`: `id TEXT PK`, `canonical_key TEXT NOT NULL UNIQUE`, `directory_json TEXT NOT NULL`, `label TEXT NOT NULL`, `legacy_restore INTEGER NOT NULL DEFAULT 0`. `canonical_key` is the JSON tuple `[kind,path,authority,documentId]`; grant URI is access capability, not directory identity.
- `storage_catalog_state`: `id INTEGER PK CHECK(id=1)`, `default_location_id TEXT NULL`, `revision INTEGER NOT NULL DEFAULT 0`, `bootstrap_version INTEGER NOT NULL DEFAULT 0`, `legacy_anchor_json TEXT NULL`, `candidate_json TEXT NULL`. Candidate JSON records token, process epoch, location, validation phase and exact owned probe receipts; an interrupted candidate never auto-commits.
- `recording_bindings`: `dump_id TEXT PK`, `incarnation TEXT NOT NULL`, `location_id TEXT NULL`, `audio_json TEXT NOT NULL`, `metadata_name TEXT NOT NULL`, `legacy_anchor_json TEXT NULL`, `resolved INTEGER NOT NULL DEFAULT 0`. Resolved requires location and proven original audio identity; unresolved requires a frozen anchor. Do not mutate any existing Dumps value.
- `capture_reservations`: `reservation_id TEXT PK`, `dump_id TEXT UNIQUE NOT NULL`, `incarnation TEXT NOT NULL`, `location_id TEXT NOT NULL`, `staging_path TEXT NOT NULL`, `mode TEXT NOT NULL`, `started_at INTEGER NOT NULL`, `state TEXT NOT NULL`, `process_epoch TEXT NOT NULL`, `publication_json TEXT NULL`. States: `reserved`, `recording`, `stopped`, `publishing`, `failed`, `committed`, `interrupted`.
- `local_deletion_batches`: `operation_id TEXT PK`, `payload_json TEXT NOT NULL`, `results_json TEXT NOT NULL`, `state TEXT NOT NULL`. Payload is deterministically sorted exact target key/binding identity; reuse with a different payload fails `conflict`.
- `local_deletion_tickets`: `dump_id TEXT PK`, `incarnation TEXT NOT NULL`, `ticket_id TEXT UNIQUE NOT NULL`, `operation_id TEXT NOT NULL`, `binding_json TEXT NOT NULL`, `audio_state TEXT NOT NULL`, `metadata_state TEXT NOT NULL`, `state TEXT NOT NULL`, `problem_json TEXT NULL`. `state` is `pending`, `failed` or `completed`; completed ticket is the retired-ID receipt and contains no transcript, notes or title. Do not cascade-delete it when removing a dump.

Relations to live rows/locations are checked transactionally; queue cleanup is explicit, not dependent on SQLite's foreign-key default. Add indexes on `capture_reservations(state)` and `local_deletion_tickets(state)`. `storage_catalog_state` receives its singleton row on fresh creation and v5 upgrade. New tables do not require a Dumps rebuild or sidecar schema change.

Encoding is versioned JSON with explicit named fields, no `toString()` persistence. `DirectoryRef`: `kind,path,authority,treeUri,documentId`; `AudioLocator`: `kind,value`; key: `dumpId,incarnation`; binding: `key,location,audio,metadataName`; location: `id,directory,label`. Validate all required fields and kind combinations on decode. Literal IDs reject empty, `.`, `..`, slash, backslash, NUL and path separators; do not normalize them. For existing unsupported IDs, persist unresolved anchors and surface a diagnostic, never rewrite the ID.

Add these exact public `LocalDb` methods in the task that owns the behavior:

```dart
// Declaration inventory for LocalDb; bodies are supplied by tasks 3–6.
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```

The C1 block already contains this database inventory; do not declare it twice. `LocalDb implements StorageDatabaseOperations` when all methods are implemented at task 6. Before then concrete methods may land incrementally; do not ship an implementation with throwing placeholders.

Existing `upsertDump`, `deleteDump`, `updateDumpTitle`, `updateDumpMeetingNotes`, `updateDumpTranscript`, `beginTranscriptionAttempt`, `updateTranscriptionStatus`, `completeTranscriptionAttempt`, `updateTranscriptionSidecarError`, `updateSyncStatus` must not remain general bypasses. At task 6 add `required RecordingKey storageKey` to each existing mutation method, preserving all other arguments/result types and clock/CAS statements. Require `id == storageKey.dumpId`, current binding incarnation, and no deletion/retirement fence in the SAME transaction/SQL predicate as the mutation. General upsert is removed from production creation/adoption callers; only a clearly test-scoped seed helper may use direct inserts. `deleteDump` becomes private finalization under the exact ticket. Tests use seeded bindings and the required key. No default key may be synthesized from the current row for a previously captured callback.

## Reusable command convention

All task test commands below run from the worktree's `client` directory unless marked repository root or Android directory. Use the full Flutter path, no output-tail pipelines. RED missing-symbol failures are scaffolding feedback, not behavioral proof: after the contract compiles, record the failing invariant before fixing its implementation. Do not change expectations to the defective behavior. Refactor only with the focused suite green. Each commit is later execution only and stages the task's explicit files, never `git add .`.

## Task 1: Shared contract, additive v5 schema and preserved-schema fixtures

**Owner:** Ted. **Depends on:** controller verification of plan. **Files:** create `client/lib/data/storage/storage_contract.dart`, `client/lib/data/storage/storage_tables.dart`, `client/test/support/storage_migration_fixture.dart`, `client/test/unit/data/storage_migration_test.dart`; modify `client/lib/data/local_db.dart:55–107` and generated `client/lib/data/local_db.g.dart`; update version assertions in `client/test/unit/data/local_db_test.dart:185,223,337` from 4 to 5 without changing v1/v2/v3 transformation expectations.

**Interfaces:** Produces C1 types, table/encoding ABI and v5 schema; no UI/runtime binding or live-file migration. Inherits the exact database ABI above.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **1.1 RED fixture: create the complete synthetic old-schema helper below.** It uses sqlite3 memory databases, not a device copy. The schema matches the actual old Drift columns, FTS external-content table and triggers. All old values are compared using raw SQL dictionaries, avoiding DateTime precision guesses.

```dart
// client/test/support/storage_migration_fixture.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:sqlite3/sqlite3.dart';

Database oldStorageDatabase(int version) {
  if (version != 3 && version != 4) throw ArgumentError.value(version);
  final db = sqlite3.openInMemory();
  db.execute('''
CREATE TABLE dumps (
 id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL, mode TEXT NOT NULL,
 duration_seconds INTEGER NOT NULL, title TEXT NOT NULL,
 transcript TEXT, meeting_notes TEXT, audio_path TEXT NOT NULL,
 audio_size_bytes INTEGER NOT NULL, sync_status TEXT NOT NULL,
 sync_attempts INTEGER NOT NULL DEFAULT 0, last_sync_error TEXT
);
CREATE TABLE sync_queue (
 id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
 dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
 queued_at INTEGER NOT NULL
);
CREATE VIRTUAL TABLE dumps_fts USING fts5(
 title, transcript, content='dumps', content_rowid='rowid'
);
CREATE TRIGGER dumps_ai AFTER INSERT ON dumps BEGIN
 INSERT INTO dumps_fts(rowid,title,transcript) VALUES(new.rowid,new.title,new.transcript);
END;
CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
 INSERT INTO dumps_fts("dumps_fts",rowid,title,transcript)
 VALUES('delete',old.rowid,old.title,old.transcript);
END;
CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
 INSERT INTO dumps_fts("dumps_fts",rowid,title,transcript)
 VALUES('delete',old.rowid,old.title,old.transcript);
 INSERT INTO dumps_fts(rowid,title,transcript) VALUES(new.rowid,new.title,new.transcript);
END;
''');
  if (version == 4) {
    for (final definition in <String>[
      "transcription_status TEXT NOT NULL DEFAULT 'not_transcribed'",
      'transcription_request_id TEXT', 'transcription_job_id TEXT',
      'transcription_attempt INTEGER NOT NULL DEFAULT 0',
      'transcription_started_at INTEGER', 'transcription_updated_at INTEGER',
      'transcription_completed_at INTEGER', 'transcription_error TEXT',
    ]) {
      db.execute('ALTER TABLE dumps ADD COLUMN $definition');
    }
  }
  const statuses = ['local_only', 'pending', 'syncing', 'synced', 'failed'];
  const transcripts = [null, '', '   ', 'retained words', 'other words'];
  const transcriptions = ['not_transcribed', 'uploading', 'queued', 'running', 'completed', 'failed'];
  for (var i = 0; i < 10; i++) {
    db.execute('''INSERT INTO dumps
(id,created_at,updated_at,mode,duration_seconds,title,transcript,meeting_notes,
 audio_path,audio_size_bytes,sync_status,sync_attempts,last_sync_error)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)''', [
      'fixture-$i', 1000 + i, 2000 + i, i.isEven ? 'meeting' : 'brain_dump',
      7 + i, 'Searchable fixture $i', transcripts[i % transcripts.length],
      'preserve notes $i', 'content://fixture/tree/root/document/audio-$i',
      10 + i, statuses[i % statuses.length], i, i.isEven ? null : 'old sync error',
    ]);
    if (version == 4) {
      db.execute('''UPDATE dumps SET transcription_status=?,transcription_request_id=?,
transcription_job_id=?,transcription_attempt=?,transcription_started_at=?,
transcription_updated_at=?,transcription_completed_at=?,transcription_error=? WHERE id=?''', [
        transcriptions[i % transcriptions.length], i.isEven ? null : 'request-$i',
        i.isEven ? null : 'job-$i', i, 3000 + i, 4000 + i,
        i.isEven ? null : 5000 + i,
        i == 4 ? 'sidecar_sync_pending: fixture' : (i == 5 ? 'retained diagnostic' : null),
        'fixture-$i',
      ]);
    }
    db.execute('INSERT INTO sync_queue(dump_id,queued_at) VALUES(?,?)', ['fixture-$i', 6000 + i]);
  }
  db.userVersion = version;
  return db;
}

List<Map<String, Object?>> sqlRows(Database db, String table) =>
    db.select('SELECT * FROM $table ORDER BY id').map((r) => Map<String, Object?>.from(r)).toList();
```

- [ ] **1.2 RED: add this complete migration test and run it before the v5 change.** Expected behavioral failure is `userVersion` 4 versus 5. The fixture itself must first create and read successfully.

```dart
// client/test/unit/data/storage_migration_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import '../../support/storage_migration_fixture.dart';

void main() {
  for (final version in [3, 4]) {
    test('v$version to v5 preserves every original column and queue row', () async {
      final sql = oldStorageDatabase(version);
      final before = sqlRows(sql, 'dumps');
      final queue = sqlRows(sql, 'sync_queue');
      final db = LocalDb.forTesting(NativeDatabase.opened(sql));
      addTearDown(db.close);
      await db.listDumps();
      expect(sql.userVersion, 5);
      final after = sqlRows(sql, 'dumps');
      expect(after, hasLength(before.length));
      for (var i = 0; i < before.length; i++) {
        expect({for (final name in before[i].keys) name: after[i][name]}, before[i]);
        if (version == 3) {
          final hasText = (before[i]['transcript'] as String?)?.trim().isNotEmpty ?? false;
          expect(after[i]['transcription_status'], hasText ? 'completed' : 'not_transcribed');
          expect(after[i]['transcription_attempt'], 0);
          expect(after[i]['transcription_completed_at'], hasText ? before[i]['updated_at'] : null);
          for (final name in ['transcription_request_id', 'transcription_job_id',
            'transcription_started_at', 'transcription_updated_at', 'transcription_error']) {
            expect(after[i][name], isNull);
          }
        }
      }
      expect(sqlRows(sql, 'sync_queue'), queue);
      final tables = sql.select("SELECT name FROM sqlite_master WHERE type='table'").map((r) => r['name']).toSet();
      expect(tables, containsAll(['storage_locations', 'storage_catalog_state',
        'recording_bindings', 'capture_reservations', 'local_deletion_batches', 'local_deletion_tickets']));
      expect(sql.select('SELECT * FROM storage_catalog_state').single['revision'], 0);
      expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');
      expect(sql.select('PRAGMA foreign_key_check'), isEmpty);
      sql.execute("INSERT INTO dumps_fts(dumps_fts, rank) VALUES('integrity-check', 1)");
      sql.execute("UPDATE dumps SET title='Changed search token' WHERE id='fixture-0'");
      expect(await db.searchDumps('Changed'), hasLength(1));
      // Synthetic SQL fixture only: verifies old FTS delete trigger, not app deletion.
      sql.execute("DELETE FROM sync_queue WHERE dump_id='fixture-0'");
      sql.execute("DELETE FROM dumps WHERE id='fixture-0'");
      expect(await db.searchDumps('Changed'), isEmpty);
    });
  }
  test('fresh v5 starts without a claimed legacy/default location', () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.listDumps();
    final state = await db.customSelect('SELECT * FROM storage_catalog_state').getSingle();
    expect(state.data['default_location_id'], isNull);
    expect(state.data['bootstrap_version'], 0);
  });
}
```

Run: `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/storage_migration_test.dart --concurrency=1 --reporter expanded`.

- [ ] **1.3 GREEN: add table definitions, retain old migrations, create only new tables when `from < 5`.** Add a private `_createStorageCatalog(Migrator m)` helper with the concrete `Migrator` type from Drift, invoking `m.createTable` for each new table, creating the two indexes and inserting the singleton with `INSERT OR IGNORE`. Call it during upgrade; on fresh create, `m.createAll()` already creates registered tables, so insert/index initialization is separate and must not call `createTable` twice. Do not run native resolution, import or metadata writes here.

```dart
// Exact migration additions inside LocalDb, after defining/registering the tables.
Future<void> initializeStorageCatalogRows() async {
  await customStatement('INSERT OR IGNORE INTO storage_catalog_state(id) VALUES(1)');
  await customStatement('CREATE INDEX IF NOT EXISTS capture_state_idx ON capture_reservations(state)');
  await customStatement('CREATE INDEX IF NOT EXISTS deletion_state_idx ON local_deletion_tickets(state)');
}
```

- [ ] **1.4 GREEN: add deterministic tag/JSON validation and equality tests for C1.** Reject malformed tags, unsafe IDs and missing SAF effective document identity. Round-trip literal Windows drive/UNC paths without URI inference. Do not replace old `audioPath` strings. Verify contract imports resolve, then regenerate with `~/AppData/Local/flutter/bin/dart.bat run build_runner build --delete-conflicting-outputs` (generated Drift output only; inspect diff).
- [ ] **1.5 Verify/refactor:** Run the migration command plus `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/local_db_test.dart test/unit/data/recording_metadata_test.dart --concurrency=1 --reporter expanded`. Keep the paused acknowledgement behavior; schema-only edits cannot repair it. Refactor duplicate new-table initialization only after green.
- [ ] **1.6 Commit at repository root:** `git add client/lib/data/storage/storage_contract.dart client/lib/data/storage/storage_tables.dart client/lib/data/local_db.dart client/lib/data/local_db.g.dart client/test/support/storage_migration_fixture.dart client/test/unit/data/storage_migration_test.dart client/test/unit/data/local_db_test.dart && git diff --cached --check && git commit -m "feat(storage): add v5 catalog and recording binding schema"`.

## Remaining task briefs

The following briefs continue the same contract and dependency graph; no task is dispatched from this planning lane.

## Task 2: Explicit-root filesystem and native SAF I/O

**Later adopted interface clarification:** Legacy inspection semantics are superseded by `docs/superpowers/specs/2026-09-15-frozen-legacy-inspection-contract.md` for Task 4 onward. Existing Task 2 reviews certify their historical commits; do not redo Task 2.

**Owner:** Ted. **Depends on:** 1. **Create:** `client/lib/data/storage/filesystem_storage_backend.dart`, `client/lib/data/storage/saf_storage_backend.dart`, `client/lib/data/storage/storage_codec.dart`, `client/android/app/src/main/kotlin/dev/tangent/tangent/storage/SafPolicy.kt`, `DocumentsPort.kt`, `AndroidDocumentsPort.kt`, `NativeIoSupervisor.kt`, `StorageChannel.kt`, `client/android/app/src/test/kotlin/dev/tangent/tangent/storage/SafPolicyTest.kt`, `NativeIoSupervisorTest.kt`, `client/test/support/storage_fixture.dart`, `client/test/unit/data/storage_backend_test.dart`. **Modify:** `client/android/app/src/main/kotlin/dev/tangent/tangent/MainActivity.kt:30–80,125–247,423–438` and `client/android/app/build.gradle:46–48`. Keep recorder/screen-awake methods intact.

**Interfaces:** Implements C1 `StorageBackend` and `IoOperation`; produces explicit-root I/O and the reusable synthetic fixture. No current-default lookup is permitted inside an I/O method.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **2.1 RED: create the reusable fixture below and the two-folder backend test.** The helper inserts only invented rows in its newly created temp DB. It intentionally uses raw insert for test seeding, never production adoption. Keep it independent of the catalog/deletion implementations that arrive later.

```dart
// client/test/support/storage_fixture.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';

StorageLocation fileLocation(String id, String path) => (
  id: id, label: id,
  directory: (kind: 'file', path: path, treeUri: '', authority: '', documentId: ''),
);
Map<String, Object?> directoryMap(DirectoryRef d) => {
  'kind': d.kind, 'path': d.path, 'treeUri': d.treeUri,
  'authority': d.authority, 'documentId': d.documentId,
};
Future<T> settled<T>(IoOperation<T> operation) async {
  try { return await operation.result; } finally { await operation.settled; }
}
T requireOk<T>(Outcome<T> result) => switch (result) {
  Ok<T>(:final value) => value,
  Fail<T>(:final problem) => throw StorageFault(problem),
};

final class StorageFixture {
  StorageFixture._(this.root, this.db);
  factory StorageFixture.create() {
    final root = Directory.systemTemp.createTempSync('tangent-storage-fixture-');
    for (final name in ['A', 'B', 'stage']) {
      Directory(p.join(root.path, name)).createSync();
    }
    return StorageFixture._(root, LocalDb.forTesting(NativeDatabase(File(p.join(root.path, 'fixture.sqlite')))));
  }
  final Directory root;
  LocalDb db;
  final StorageBackend backend = FilesystemStorageBackend();
  Future<void> reopen() async {
    await backend.drain();
    await db.close();
    db = LocalDb.forTesting(NativeDatabase(File(p.join(root.path, 'fixture.sqlite'))));
  }
  String directory(String name) => p.join(root.path, name);
  File audio(String folder, String id) => File(p.join(directory(folder), '$id.opus'));
  File metadata(String folder, String id) => File(p.join(directory(folder), '$id.meta.json'));
  Future<BoundRecording> seed(String id, {String folder = 'A', String status = 'not_transcribed',
      String sync = 'local_only', String? error}) async {
    if (!id.startsWith('fixture-')) throw ArgumentError('Synthetic IDs only');
    final location = fileLocation(folder, directory(folder));
    final bytes = [1, 2, 3];
    await audio(folder, id).writeAsBytes(bytes, flush: true);
    await metadata(folder, id).writeAsString(jsonEncode({'schemaVersion': 2, 'id': id, 'title': id}), flush: true);
    final now = DateTime.utc(2030, 1, 2);
    final row = DumpRow(id: id, createdAt: now, updatedAt: now, mode: 'brain_dump',
      durationSeconds: 3, title: id, transcript: status == 'completed' ? 'retained words' : null,
      meetingNotes: 'retained notes', audioPath: audio(folder,id).path, audioSizeBytes: bytes.length,
      syncStatus: sync, syncAttempts: 0, transcriptionStatus: status,
      transcriptionAttempt: status == 'not_transcribed' ? 0 : 1,
      transcriptionRequestId: status == 'not_transcribed' ? null : 'request-$id',
      transcriptionJobId: status == 'running' ? 'job-$id' : null, transcriptionError: error);
    await db.into(db.dumps).insert(row);
    await db.customStatement('INSERT OR IGNORE INTO storage_locations(id,canonical_key,directory_json,label) VALUES(?,?,?,?)',
      [folder, jsonEncode([location.directory.kind, location.directory.path, location.directory.authority, location.directory.documentId]), jsonEncode(directoryMap(location.directory)), folder]);
    await db.customStatement('''INSERT INTO recording_bindings
(dump_id,incarnation,location_id,audio_json,metadata_name,resolved) VALUES(?,?,?,?,?,1)''',
      [id, 'incarnation-$id', folder, jsonEncode({'kind': 'file', 'value': row.audioPath}), '$id.meta.json']);
    return (key: (dumpId: id, incarnation: 'incarnation-$id'), location: location,
      audio: (kind: 'file', value: row.audioPath), metadataName: '$id.meta.json');
  }
  Future<void> close() async {
    await backend.drain();
    await db.close();
    await root.delete(recursive: true);
  }
}
```

```dart
// client/test/unit/data/storage_backend_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../../support/storage_fixture.dart';

void main() {
  test('bound A read/delete never follows same-ID B decoy', () async {
    final f = StorageFixture.create(); addTearDown(f.close);
    final a = await f.seed('fixture-a');
    await f.audio('B','fixture-a').writeAsBytes([9,9,9]);
    await f.metadata('B','fixture-a').writeAsString('unrelated');
    expect(requireOk(await settled(f.backend.readAudio(a))), [1,2,3]);
    final removed = await settled(f.backend.deleteComponent(a, RecordingComponent.audio, 'op-audio'));
    expect(removed.state, ComponentState.removed);
    final absent = await settled(f.backend.deleteComponent(a, RecordingComponent.audio, 'op-audio-again'));
    expect(absent.state, ComponentState.absent);
    expect(await f.audio('B','fixture-a').readAsBytes(), [9,9,9]);
    expect(await f.metadata('B','fixture-a').readAsString(), 'unrelated');
  });
  test('directory masquerading as metadata is never recursively deleted', () async {
    final f = StorageFixture.create(); addTearDown(f.close);
    final a = await f.seed('fixture-a');
    await f.metadata('A','fixture-a').delete();
    final directory = await Directory(f.metadata('A','fixture-a').path).create();
    await File('${directory.path}/keep').writeAsString('unrelated');
    final result = await settled(f.backend.deleteComponent(a, RecordingComponent.metadata, 'op-directory'));
    expect(result.state, ComponentState.failed);
    expect(await File('${directory.path}/keep').readAsString(), 'unrelated');
  });
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/storage_backend_test.dart --concurrency=1 --reporter expanded`. First missing API failures are not sufficient RED; after constructor/port scaffolding compiles, demonstrate the directory/decoy invariant fails on the legacy-routing adapter before replacing it. Do not expose that temporary adapter through main.

- [ ] **2.2 GREEN: implement the filesystem operations against each supplied binding.** Resolve the authorized root once; validate exact audio parent/file identity and generated metadata basename, inspect links with `FileSystemEntity.type(..., followLinks: false)`, reject directories/links, and preserve OS exceptions as typed failures. Publish using unique operation-owned temporary paths; existing capture targets cause conflict, not overwrite. Metadata replacement is allowed only for the bound owned component under the publication lane. Never remove arbitrary `.tmp`/`.partial` names. Return actual component results and keep staging untouched.

```dart
// Core filesystem deletion algorithm inside FilesystemStorageBackend.
Future<ComponentResult> removeRegularFile(String path) async {
  try {
    // Import package:path/path.dart as p in the backend. A successful parent
    // enumeration, not FileSystemEntity.type alone, is the absence proof.
    final name = p.basename(path);
    final entries = await Directory(p.dirname(path)).list(followLinks: false).toList();
    final listed = entries.any((entry) {
      final candidate = p.basename(entry.path);
      return candidate == name || (Platform.isWindows && candidate.toLowerCase() == name.toLowerCase());
    });
    if (!listed) return (state: ComponentState.absent, problem: null);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (state: ComponentState.unknown,
        problem: (code: ProblemCode.unknown, message: 'Listed component could not be inspected'));
    }
    if (type != FileSystemEntityType.file) {
      return (state: ComponentState.failed,
        problem: (code: ProblemCode.invalid, message: 'Not an owned regular file'));
    }
    await File(path).delete();
    return (state: ComponentState.removed, problem: null);
  } on FileSystemException catch (error) {
    return (state: ComponentState.failed,
      problem: (code: ProblemCode.io, message: error.message));
  }
}
```

- [ ] **2.3 RED native policy: add JUnit and the concrete fake/provider tests below.** Pure policy has no Android dependencies; `AndroidDocumentsPort` is the only ContentResolver adapter. Native ABI: `NativeDirectory(authority:String,treeUri:String,documentId:String)`, `NativeNode(id:String,name:String,directory:Boolean)`, `DocumentsPort.children(directory):List<NativeNode>`, `delete(directory,node):Boolean`; `SafPolicy(port).effectiveDirectory(selected,legacy):NativeDirectory`, `deleteComponent(directory,name,expectedDocumentId:String?):NativeComponentResult`. `NativeComponentResult.state` is `removed|absent|failed|unknown`; `NativeStorageException.code` is a C1 ProblemCode wire name. These exact declarations go in `DocumentsPort.kt` before the policy and its tests:

```kotlin
// client/android/app/src/main/kotlin/dev/tangent/tangent/storage/DocumentsPort.kt
// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage
data class NativeDirectory(val authority: String, val treeUri: String, val documentId: String)
data class NativeNode(val id: String, val name: String, val directory: Boolean, val virtual: Boolean = false)
class NativeStorageException(val code: String, message: String) : RuntimeException(message)
data class NativeComponentResult(val state: String, val problem: NativeStorageException? = null)
interface DocumentsPort {
    fun name(directory: NativeDirectory): String
    fun children(directory: NativeDirectory): List<NativeNode>
    fun delete(directory: NativeDirectory, node: NativeNode): Boolean
}
```

```kotlin
// client/android/app/src/test/kotlin/dev/tangent/tangent/storage/SafPolicyTest.kt
package dev.tangent.tangent.storage
import org.junit.Assert.*
import org.junit.Test

private class MemoryDocuments : DocumentsPort {
    val entries = mutableMapOf<String, List<NativeNode>>()
    val deleted = mutableListOf<String>()
    var denied = false
    var deleteSucceeds = true
    override fun name(directory: NativeDirectory): String = when (directory.documentId) {
        "opaque-parent" -> "Documents"
        "opaque-child" -> "Tangent"
        else -> "Chosen folder"
    }
    override fun children(directory: NativeDirectory): List<NativeNode> {
        if (denied) throw NativeStorageException("denied", "Grant revoked")
        return entries[directory.documentId] ?: emptyList()
    }
    override fun delete(directory: NativeDirectory, node: NativeNode): Boolean {
        deleted.add(node.id)
        if (deleteSucceeds) entries[directory.documentId] = children(directory).filter { it.id != node.id }
        return deleteSucceeds
    }
}
class SafPolicyTest {
    @Test fun legacyChildButNewSelectionIsDirect() {
        val docs = MemoryDocuments()
        val parent = NativeDirectory("provider", "content://provider/tree/grant", "opaque-parent")
        docs.entries[parent.documentId] = listOf(NativeNode("opaque-child", "Tangent", true))
        val policy = SafPolicy(docs)
        assertEquals("opaque-child", policy.effectiveDirectory(parent, true).documentId)
        assertEquals(parent, policy.effectiveDirectory(parent, false))
    }
    @Test fun falseDeleteAndDeniedEnumerationAreNotAbsence() {
        val docs = MemoryDocuments()
        val dir = NativeDirectory("provider", "content://provider/tree/grant", "opaque-child")
        docs.entries[dir.documentId] = listOf(NativeNode("audio-id", "fixture-a.opus", false))
        val policy = SafPolicy(docs)
        docs.deleteSucceeds = false
        assertEquals("failed", policy.deleteComponent(dir, "fixture-a.opus", "audio-id").state)
        docs.denied = true
        assertEquals("failed", policy.deleteComponent(dir, "fixture-a.meta.json", null).state)
    }
    @Test fun directoryOrWrongDocumentIdentityIsNeverDeleted() {
        val docs = MemoryDocuments()
        val dir = NativeDirectory("provider", "content://provider/tree/grant", "root")
        docs.entries[dir.documentId] = listOf(NativeNode("other", "fixture-a.opus", false),
            NativeNode("directory", "fixture-a.meta.json", true))
        val policy = SafPolicy(docs)
        assertEquals("failed", policy.deleteComponent(dir, "fixture-a.opus", "owned").state)
        assertEquals("failed", policy.deleteComponent(dir, "fixture-a.meta.json", null).state)
        assertTrue(docs.deleted.isEmpty())
    }
}
```

Add `testImplementation "junit:junit:4.13.2"` to the existing Gradle dependencies; no production dependency changes. From `client/android`: `./gradlew.bat :app:testDebugUnitTest --tests 'dev.tangent.tangent.storage.SafPolicyTest' --console=plain`. No connected/device test target.

- [ ] **2.4 GREEN native mapping/outcomes:** Implement `SafPolicy` against this port. Legacy-root resolution reads the selected node's display name through an explicit port query (`name(directory):String`, add it to the port/fake with `opaque-parent→Documents`, `opaque-child→Tangent`); Documents requires exactly one existing Tangent directory, Tangent is direct. New selection never takes the legacy branch. Binding additionally proves enumerated audio ID matches stored audio locator. `AndroidDocumentsPort` uses `DocumentsContract` tree-aware document/children URIs with the effective document ID; do not split opaque IDs, use prefix grants or `DocumentFile.listFiles` error swallowing. Query failure/null cursor is an error, not empty children. Check delete booleans and file flags/type; never recursively delete a directory.
- [ ] **2.5 RED/GREEN actual worker lifetime:** Add `NativeIoSupervisorTest.kt` with two `CountDownLatch` gates: submit a writer, assert its `settled.isDone` false while blocked, detach/recreate the channel owner, queue same-binding delete, assert delete has not entered, release writer, then assert write precedes delete and both settle. In `finally`, release every latch and close the supervisor. Implement a process-owned supervisor, not activity-owned threads. Native operation ABI: `submit<T>(key:String, action:()->T):NativeOperation<T>`; operation has `id:String`, `result:CompletableFuture<T>`, `settled:CompletableFuture<Unit>`. `settled` completes only from the worker's actual `finally`, never from Flutter result delivery/channel detach. Per-key FIFO covers both write and delete. Record completed results until acknowledged by the new channel owner.
```kotlin
// client/android/app/src/test/kotlin/dev/tangent/tangent/storage/NativeIoSupervisorTest.kt
// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.tangent.tangent.storage
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
class NativeIoSupervisorTest {
    @Test fun replacementObserverCannotLoseOutstandingWriter() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<String>())
        val supervisor = NativeIoSupervisor(Executors.newFixedThreadPool(2))
        try {
            val write = supervisor.submit("fixture/root/a") {
                entered.countDown()
                check(release.await(2, TimeUnit.SECONDS))
                order.add("write")
            }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertFalse(write.settled.isDone)
            // A replacement bridge observes the process-owned same operation.
            assertSame(write, supervisor.operation(write.id))
            val delete = supervisor.submit("fixture/root/a") { order.add("delete") }
            assertFalse(delete.settled.isDone)
            release.countDown()
            write.settled.get(2, TimeUnit.SECONDS)
            delete.settled.get(2, TimeUnit.SECONDS)
            assertEquals(listOf("write", "delete"), order.toList())
        } finally {
            release.countDown()
            supervisor.close()
        }
    }
}
```

Complete native constructor/lookup ABI: `NativeIoSupervisor(executor:ExecutorService) : AutoCloseable`; `operation(id:String):NativeOperation<*>?`; `close()` drains then shuts down only this test-owned executor. Production uses one process-owned instance and does not close it on Activity/engine detach. `activeOperations` channel response includes operation ID, recording key and use kind; `StorageBackend.unsettledUses()` reattaches actual settled signals. Bootstrap must call `restoreFences(unsettled: await backend.unsettledUses())` before any capture/default commit/deletion. Thus a recreated Dart owner cannot forget a still-running native worker merely because its old result channel vanished. Failure to enumerate/reobserve native work keeps bootstrap unavailable for mutations, not an empty active set.

- [ ] **2.6 Channel wiring:** Keep existing channel name. New messages are `inspectLegacyStorage`, `pickDirectory`, `validateCandidate`, `readAudioAt`, `playbackSourceAt`, `publishCaptureAt`, `writeMetadataAt`, `deleteComponentAt`, `listRecordingsAt`, `activeOperations`, `operationState`, `acknowledgeOperation`. Each I/O start includes `operationId`, full binding/reservation JSON and returns an operation handle. `operationState` returns `pending|settled`, result or typed problem. Dart `result` may fail on channel loss, but `settled` waits for native proof via the reattached channel; do not fabricate settled on a timeout. Candidate picker returns null for Cancel without writing preferences. Persist grant modes, validate with uniquely owned read/write/rename/delete probes, record their exact URIs, and never release old grants.
- [ ] **2.7 Verify/refactor and commit:** Run the Dart backend test and `./gradlew.bat :app:testDebugUnitTest --console=plain`; extend the policy table to arbitrary names, direct Tangent, missing/duplicate legacy child, equivalent grants versus prefix lookalikes, failed create/rename/probe cleanup and detached channel. Record exact names/counts. Stage the explicit files listed above, inspect `git diff --cached --check`, then `git commit -m "feat(storage): route filesystem and SAF operations by immutable locator"`. No main/app switch UI yet.

## Task 3: Admission, real-I/O lifetime, publication FIFO and retirement primitives

**Owner:** Ted. **Depends on:** 1, 2. **Create:** `client/lib/data/storage/recording_mutation_coordinator.dart`, `recording_access.dart`, `client/test/unit/data/storage_lifetime_test.dart`, `storage_retirement_test.dart`. **Modify:** `client/lib/data/local_db.dart` and generated schema only if an omitted index is required by the fixed schema. Implement concrete database ABI `boundRecording`, `bindRecording`, `isRetired`, `mutationAllowed`, `claimLocalDeletion`, `recordDeletionComponent`, `finishLocalDeletion`, `pendingLocalDeletions` now; defer enabling new public callers to task 6.

**Interfaces:** Produces C1 leases, actual-I/O retention, `RecordingAccess`, deletion admission and durable ticket primitives. This task does not execute a deletion batch or allocate a transcription identity.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **3.1 RED: add the complete outer-timeout test below.** The gate represents real I/O. Its value future is separate from its actual settled signal. Completion of an outer timeout must leave Delete busy. Teardown releases gates before draining/closing fixtures.

```dart
// client/test/unit/data/storage_lifetime_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';

final class GatedIo<T> implements IoOperation<T> {
  GatedIo(this.id);
  @override final String id;
  final value = Completer<T>();
  final done = Completer<void>();
  @override Future<T> get result => value.future;
  @override Future<void> get settled => done.future;
}
void main() {
  test('outer timeout and close do not release outstanding real I/O', () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-lifetime');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final io = GatedIo<int>('fixture-io');
    addTearDown(() async {
      if (!io.value.isCompleted) io.value.complete(7);
      if (!io.done.isCompleted) io.done.complete();
      await m.drain(); await f.close();
    });
    await m.restoreFences();
    final lease = requireOk(await m.acquire(a.key.dumpId, UseKind.publication,
      expectedIncarnation: a.key.incarnation));
    final retained = m.runIo(lease, () => io);
    await expectLater(retained.timeout(Duration.zero), throwsA(isA<TimeoutException>()));
    final closing = lease.close();
    io.value.complete(7);
    expect(await retained, 7);
    final busy = await m.acquire(a.key.dumpId, UseKind.deletion,
      expectedIncarnation: a.key.incarnation);
    expect(busy, isA<Fail<UseLease>>());
    expect((busy as Fail<UseLease>).problem.code, ProblemCode.busy);
    io.done.complete(); await closing;
    final deletion = requireOk(await m.acquire(a.key.dumpId, UseKind.deletion,
      expectedIncarnation: a.key.incarnation));
    await deletion.close();
  });
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/storage_lifetime_test.dart --concurrency=1 --reporter expanded`. Also force the inverse `result` failure-before-settled case; failure must not release the child pin.

- [ ] **3.2 GREEN admission:** Reserve the per-ID slot synchronously before awaiting DB binding/eligibility. Shared use increments a counter; deletion is exclusive and rejects nonzero users/queued publishers. Resolve/compare incarnation, persisted nonterminal/sync state and ticket under the admission. Ordinary use rejects any deletion fence/retired key. `restoreFences` loads pending/completed tickets before admission is enabled. Future provider recreation receives the same instance, never a replacement map.
- [ ] **3.3 GREEN retention:** `runIo` registers a child pin before invoking `start`; return the underlying result, but decrement that child only when `settled` proves completion. `UseLease.close` prevents new children immediately and returns a future completed only after all existing children settle. A caller may stop observing without waiting for close; the app-owned registry retains the pin. Catch synchronous `start` failure by releasing only its never-dispatched child. Implement `drain` for controlled teardown, not a production permission to cancel workers.

```dart
// Essential retention ordering; _retainChild/_releaseChild belong to the lease implementation.
Future<T> retainActualIo<T>(void Function() retain, void Function() release,
    IoOperation<T> Function() start) {
  retain();
  late IoOperation<T> operation;
  try { operation = start(); } catch (_) { release(); rethrow; }
  unawaited(operation.settled.then((_) { release(); }));
  return operation.result;
}
```

The backend contract guarantees `settled` never rejects: an operation result may fail, but settled is a positive termination signal. An adapter unable to prove termination keeps the fence and reports unknown/busy; it cannot unblock destruction.

- [ ] **3.4 RED/GREEN FIFO/access:** Add two gated `runSerializedMetadataWrite` calls; second must read the DB only after first finishes, and a failed first caller must not poison the queue. `BoundRecordingAccess` acquires a publication lease before enqueueing, passes a raw bound writer callback and retains its actual backend I/O. Do not reacquire the same FIFO from that callback. `openAudio` and `openPlayback` use bound sources and leases; playback close awaits the existing engine's dispose, including a pending load, before releasing protection.
- [ ] **3.5 RED/GREEN retirement:** Use fixture A, create the exact ticket through `claimLocalDeletion`, then attempt wrong-incarnation mutation and binding reuse; both fail. Record audio and metadata removed, finalize, reopen the temp DB, assert retired true, row/binding/queue absent and FTS empty. A new insertion with the retired ID must conflict. Include pending ticket restart: `restoreFences` blocks new acceptance/publication without deleting any file. Atomic claim SQL must reread current status, `syncing`, pending sidecar marker and binding; preserve nullable request and every pre-existing CAS condition. No SQLite transaction spans provider I/O.

```dart
// client/test/unit/data/storage_retirement_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../../support/storage_fixture.dart';
void main() {
  test('durable fence and retired ID reject wrong/stale ownership', () async {
    final f = StorageFixture.create(); addTearDown(f.close);
    final a = await f.seed('fixture-retired');
    expect(await f.db.mutationAllowed((dumpId: a.key.dumpId, incarnation: 'wrong')), isFalse);
    final target = (id: a.key.dumpId, binding: a, title: 'Synthetic', eligibility: Eligibility.eligible, retryTicketId: null);
    final ticket = requireOk(await f.db.claimLocalDeletion('fixture-batch', target));
    expect(await f.db.mutationAllowed(a.key), isFalse);
    await f.db.recordDeletionComponent(ticket.id, RecordingComponent.audio,
      (state: ComponentState.removed, problem: null));
    await f.db.recordDeletionComponent(ticket.id, RecordingComponent.metadata,
      (state: ComponentState.absent, problem: null));
    await f.db.finishLocalDeletion(ticket.id);
    expect(await f.db.getDump(a.key.dumpId), isNull);
    expect(await f.db.boundRecording(a.key.dumpId), isNull);
    expect(await f.db.isRetired(a.key.dumpId), isTrue);
    await expectLater(f.db.bindRecording(a), throwsA(isA<StorageFault>()));
    final stored = await f.db.customSelect('SELECT * FROM local_deletion_tickets').getSingle();
    expect(stored.data['state'], 'completed');
    expect(stored.data.toString(), isNot(contains('retained words')));
    expect(stored.data.toString(), isNot(contains('retained notes')));
  });
}
```

This primitive test models component receipts; task 6 independently proves that only actual backend success/verified absence produces those receipts. It does not claim that this test deleted its fixture files.

- [ ] **3.6 Verify/refactor/commit:** Run both new tests and the backend/migration tests. Recheck actual `settled` ownership versus caller completion. Stage `recording_mutation_coordinator.dart`, `recording_access.dart`, the two new tests and exact LocalDb changes; `git diff --cached --check && git commit -m "feat(storage): fence mutations and retain actual I/O ownership"`.

## Task 4: Frozen legacy bootstrap and SQLite-only default catalog

**Required adopted prerequisite:** Read `docs/superpowers/specs/2026-09-15-frozen-legacy-inspection-contract.md` in full. Its exact API/envelope/capture-freeze-resolve/diagnostic/test decisions govern. Its bounded native/Dart/contract/test file inventory is explicitly added to Task 4 allowed scope, overriding the narrower Modify list below. Implement and verify the prerequisite before catalog recovery; preserve earlier accepted behavior outside that correction.

**Owner:** Ted. **Depends on:** 1–3. **Create:** `client/lib/data/storage/storage_catalog.dart`, `client/test/support/scripted_storage_backend.dart`, `client/test/unit/data/storage_catalog_test.dart`, `storage_legacy_binding_test.dart`. **Modify:** only storage codecs/LocalDb storage helpers needed by the fixed catalog ABI. No Settings UI and no call to unrestricted import.

**Interfaces:** Produces C1 `StorageCatalog`, candidate/default results and capture reservations; uses C1 backend and the coordinator's catalog admission lane. Legacy bootstrap accepts the explicit legacy filesystem path; Android reads the frozen native preference instead.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **4.1 RED: add this controllable backend and persisted-default test.** It uses real filesystem validation for successful choices and only fakes the picker response. It also provides component fault injection for task 6.

```dart
// client/test/support/scripted_storage_backend.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
final class ImmediateIo<T> implements IoOperation<T> {
  ImmediateIo(this.id, T value) : result = Future.value(value);
  @override final String id;
  @override final Future<T> result;
  @override Future<void> get settled => Future.value();
}
class ScriptedStorageBackend extends FilesystemStorageBackend {
  Outcome<StorageLocation?> choice = const Ok<StorageLocation?>(null);
  bool validationFails = false;
  bool metadataDeleteFails = false;
  int componentCalls = 0;
  @override Future<Outcome<StorageLocation?>> pickDirectory() async => choice;
  @override IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location) {
    if (validationFails) return ImmediateIo('probe-$token', const Fail<ProbeReceipt>(
      (code: ProblemCode.denied, message: 'synthetic validation denial')));
    return super.validateCandidate(token, location);
  }
  @override IoOperation<ComponentResult> deleteComponent(BoundRecording binding,
      RecordingComponent component, String operationId) {
    componentCalls++;
    if (metadataDeleteFails && component == RecordingComponent.metadata) {
      return ImmediateIo(operationId, (state: ComponentState.failed,
        problem: (code: ProblemCode.denied, message: 'synthetic metadata denial')));
    }
    return super.deleteComponent(binding, component, operationId);
  }
}
```

```dart
// client/test/unit/data/storage_catalog_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';
void main() {
  test('cancel, failed validation, failed commit and restart preserve authority', () async {
    final f = StorageFixture.create();
    await f.seed('fixture-old');
    final backend = ScriptedStorageBackend();
    final mutations = DefaultRecordingMutationCoordinator(db: f.db);
    var counter = 0;
    SqliteStorageCatalog catalog() => SqliteStorageCatalog(db: f.db, backend: backend,
      mutations: mutations, stagingDirectory: f.directory('stage'),
      idFactory: () => 'fixture-token-${counter++}', now: () => DateTime.utc(2030), canChooseDefault: true);
    addTearDown(() async { await backend.drain(); await mutations.drain(); await f.close(); });
    await mutations.restoreFences();
    final first = catalog();
    requireOk(await first.bootstrapLegacyBindings(filesystemLegacyDirectory: f.directory('A')));
    final original = await first.watchDefault().first;
    expect(requireOk(await first.chooseFolderCandidate()), isNull);
    expect(await first.watchDefault().first, original);
    backend.choice = Ok(fileLocation('B', f.directory('B')));
    backend.validationFails = true;
    expect(await first.chooseFolderCandidate(), isA<Fail<FolderCandidate?>>());
    expect(await first.watchDefault().first, original);
    backend.validationFails = false;
    final candidate = requireOk(await first.chooseFolderCandidate())!;
    await f.db.customStatement('''CREATE TRIGGER reject_default BEFORE UPDATE ON storage_catalog_state
WHEN NEW.default_location_id IS NOT OLD.default_location_id
BEGIN SELECT RAISE(ABORT, 'synthetic commit failure'); END''');
    expect(await first.commitDefault(candidate, expectedRevision: original.revision),
      isA<Fail<DefaultFolderState>>());
    expect((await first.watchDefault().first).location, original.location);
    await f.db.customStatement('DROP TRIGGER reject_default');
    final replacement = requireOk(await first.chooseFolderCandidate())!;
    final committed = requireOk(await first.commitDefault(replacement, expectedRevision: original.revision));
    expect(committed.location!.directory.path, f.directory('B'));
    expect((await catalog().watchDefault().first).location, committed.location);
    expect((await f.db.boundRecording('fixture-old'))!.location.directory.path, f.directory('A'));
    expect(await f.db.listDumps(), hasLength(1));
  });
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/storage_catalog_test.dart --concurrency=1 --reporter expanded`. Failure must identify default/readiness change, missing persisted authority or wrong-root binding—not a fixture permission prompt.

- [ ] **4.2 GREEN bootstrap:** Freeze native `recordings_tree_uri`/legacy policy or explicit old filesystem root exactly once in `legacy_anchor_json`. Resolve each unbound old row by proof against its original audio identity. Insert a stable incarnation/binding or unresolved anchor, in resumable chunks with a persisted completion version. No file creation, movement, metadata write or transcript mutation. Healthy old rows keep working even if the current default is missing. Bind unresolved rows only against their original anchor when access returns; never against the later default.
- [ ] **4.3 RED/GREEN legacy tests:** In `storage_legacy_binding_test.dart`, insert v4-shaped rows without bindings via the fixture DB and feed legacy-native responses for Documents/Tangent, Tangent/direct, missing grant and ambiguous child. Recreate the catalog after changing default and assert unresolved row's `audio_json` and `legacy_anchor_json` are unchanged and destructive admission returns unresolved. Compare every original Dumps field before/after bootstrap. Use opaque document IDs, including a child whose tree portion still refers to its parent.
- [ ] **4.4 GREEN candidate state machine:** Pick result is `Ok(null)` for Cancel, `Fail(interrupted)` for lost activity, or a selected location. Persist a fresh candidate token/process epoch and probe phase before validation. `validateCandidate` returns exact owned probe receipts and cleanup status. Only cleaned, validated candidates can commit. On restart invalidate uncommitted candidates; never apply them automatically. Never revoke existing grants. Probe failure/unknown cleanup reports error and leaves the committed default/readiness unchanged.
- [ ] **4.5 GREEN commit/reserve serialization:** Execute candidate consume/location registration/default revision update in one DB transaction inside `mutations.catalogAdmission`. Check candidate token, same process epoch, expected revision and absence of active reservation/native finalization. Same directory returns unchanged state without relocating bindings. Failed DB commit keeps the prior pointer; uncertain acknowledgement rereads authoritative state instead of rolling back blindly. `reserveCapture(mode)` uses the same admission lane, unused ID/incarnation, fixed destination/staging path, current process epoch and state `reserved` before returning. Settled failed/interrupted saves do not count as active; unsettled real I/O does.

```dart
// Candidate commit ordering, inside SqliteStorageCatalog; concrete DB operations stay transactional.
Future<Outcome<DefaultFolderState>> serializeDefaultCommit(
    RecordingMutationCoordinator mutations,
    Future<Outcome<DefaultFolderState>> Function() transaction) =>
  mutations.catalogAdmission(transaction);
```

- [ ] **4.6 Verify/refactor/commit:** Extend the existing test with `reserveCapture`, attempt commit and assert `busy`; mark the synthetic reservation failed, retry with a fresh candidate and assert success without changing its pinned location. Test stale revision, reused token, two pending chooser callbacks and interrupted candidate reconstruction. Run both catalog tests plus tasks 1–3 tests. Stage exact task files and `git commit -m "feat(storage): bind legacy recordings and commit default candidates atomically"` after cached diff review.

## Task 5: Pinned capture persistence and source-bound import

**Adopted Task5 publication correction (phase-A transitional C1):** Read `docs/superpowers/specs/2026-09-15-capture-publication-handoff-contract.md` in full. It governs exact prepare/SQLite-freeze/initialize/reconcile behavior, identity ports, crypto dependency, journal/wire shapes, scoped files and test matrix. During phase A only, C1 retains legacy publishCapture alongside new primitives to remain compilable; phase B removes the legacy method and all callers atomically. Task5 is not accepted until integration and scoped review pass. Earlier one-shot publication wording is superseded. No old semantic metadata/timestamp/CAS changes or phone operations.

**Owner:** Ted. **Depends on:** 1–4. **Create:** `client/lib/services/recording_coordinator.dart`, `client/lib/data/storage/recording_importer.dart`, `client/test/unit/services/pinned_recording_test.dart`, `client/test/unit/data/storage_import_test.dart`. **Modify:** `client/lib/services/recording_service.dart`, `recording_persistence.dart`, `client/lib/data/recording_metadata.dart` (import validation only), `client/test/unit/services/recording_service_test.dart`, `recording_persistence_test.dart`, `client/test/widget/recording_controller_test.dart`. Existing runtime caller wiring completes in task 6.

**Interfaces:** Produces C1 `RecordingCoordinator`, `RecordingImporter`; exact recorder ABI changes `RecordingService.start()` to `Future<String> start({required String stagingPath})`, on real/stub/fake implementations. Keep amplitude/stop/dispose contracts. Backend publish returns `PublishedCapture` and never removes staging.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **5.1 RED: add a recorder that writes only the supplied synthetic staging path and a gated DB-finalization failure test.** Capture destination is reserved before recorder start; it is not inferred from whatever default exists at stop.

```dart
// client/test/unit/services/pinned_recording_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/recording_coordinator.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';
final class FileRecorder implements RecordingService {
  @override bool isRecording = false;
  @override String? currentPath;
  @override Future<bool> requestPermission() async => true;
  @override Stream<double> amplitudeStream(Duration interval) => const Stream.empty();
  @override Future<String> start({required String stagingPath}) async {
    currentPath = stagingPath; isRecording = true;
    await File(stagingPath).writeAsBytes([1,2,3], flush: true); return stagingPath;
  }
  @override Future<RecordingResult?> stop() async {
    isRecording = false;
    return RecordingResult(path: currentPath!, durationSeconds: 3, sizeBytes: 3);
  }
  @override Future<void> dispose() async { isRecording = false; }
}
void main() {
  test('capture pins old root and preserves staging when DB insertion fails', () async {
    final f = StorageFixture.create(); final backend = ScriptedStorageBackend();
    final m = DefaultRecordingMutationCoordinator(db: f.db); var id = 0;
    final catalog = SqliteStorageCatalog(db:f.db, backend:backend, mutations:m,
      stagingDirectory:f.directory('stage'), idFactory:()=> 'fixture-capture-${id++}',
      now:()=>DateTime.utc(2030), canChooseDefault:true);
    final recorder = FileRecorder();
    final coordinator = DefaultRecordingCoordinator(db:f.db, catalog:catalog, backend:backend,
      mutations:m, recorder:recorder, now:()=>DateTime.utc(2030));
    addTearDown(() async { await recorder.dispose(); await backend.drain(); await m.drain(); await f.close(); });
    await m.restoreFences();
    requireOk(await catalog.bootstrapLegacyBindings(filesystemLegacyDirectory:f.directory('A')));
    final old = await catalog.watchDefault().first;
    final reservation = requireOk(await coordinator.start(mode:'meeting'));
    backend.choice = Ok(fileLocation('B', f.directory('B')));
    final candidate = requireOk(await catalog.chooseFolderCandidate())!;
    final busy = await catalog.commitDefault(candidate, expectedRevision:old.revision);
    expect(busy, isA<Fail<DefaultFolderState>>());
    expect((busy as Fail<DefaultFolderState>).problem.code, ProblemCode.busy);
    await f.db.customStatement("CREATE TRIGGER fail_capture BEFORE INSERT ON dumps BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END");
    expect(await coordinator.stopAndPersist(), isA<Fail<DumpRow?>>());
    expect(await File(reservation.stagingPath).readAsBytes(), [1,2,3]);
    expect(await f.audio('A',reservation.key.dumpId).readAsBytes(), [1,2,3]);
    expect(await f.audio('B',reservation.key.dumpId).exists(), isFalse);
    expect(await f.db.getDump(reservation.key.dumpId), isNull);
    final saved = await f.db.customSelect('SELECT * FROM capture_reservations').getSingle();
    expect(saved.data['state'], 'failed');
    expect(saved.data['staging_path'], reservation.stagingPath);
  });
}
```

Import `package:tangent/data/local_db.dart` in this test for `DumpRow` (included above). Move the complete `FileRecorder` class above into `client/test/support/file_recorder.dart` with its `dart:io` and `recording_service.dart` imports, then import that support file here and in task 6; do not import one test file from another. Add the support file to task 5's create/stage set. Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/services/pinned_recording_test.dart --concurrency=1 --reporter expanded`.

- [ ] **5.2 GREEN recorder/controller lifecycle:** Pass the reservation path into the existing recorder, preserving RecordConfig (Opus/16kHz/mono/32000). Keep state starting/recording/finalizing until the full pipeline settles. Record `stopped` only after a valid `RecordingResult`; a recording interrupted before a known stop is retained but not blindly imported as complete. Save mode at reservation, not after an await when UI mode may have changed.
- [ ] **5.3 GREEN publication:** Build the same initial semantic `DumpRow`/schema-2 metadata as today, publish both artifacts in the reserved root without deleting staging, then transactionally insert-if-unclaimed row+binding and mark reservation committed. `publication_json` records the stopped result, initial metadata and exact owned receipts needed for recovery; it is not a second editable transcript store. Only then remove that reservation's staging file. After staging is verified absent, remove the completed reservation. If staging cleanup fails, retain its journal and expose cleanup-pending eligibility for that recording; default changes remain allowed once actual I/O has settled, but local deletion cannot claim that row until owned-capture recovery completes cleanup. Recovery of a committed reservation only verifies the same row/binding and cleans its own staging source; it never reinserts or rewrites semantic metadata. Final deletion asserts no outstanding capture/staging journal for that ID. If row insert conflicts, retain staging and owned receipts, never overwrite an existing ID. An unused-ID decision checks Dumps, bindings, capture reservations and retired tickets atomically; only the matching reservation owner may finalize its reserved ID. A source-path mismatch from recorder is an error; no silent substitution. Do not change initial/current acknowledgement timestamp semantics to chase parity.

```dart
// Staging cleanup belongs after successful durable row/binding commit.
Future<void> cleanupCommittedStaging(CaptureReservation reservation, bool committed) async {
  if (!committed) return;
  final source = File(reservation.stagingPath);
  if (await source.exists()) await source.delete();
}
```

- [ ] **5.4 RED/GREEN import:** Implement exact outcomes `adopted`, `alreadyKnown`, `collision`, `retired`, `invalid`, `unavailable`. `preview(source)` enumerates only the supplied root, validates filename/metadata ID, supported schema 1/2 and typed fields independently per entry. `adoptConfirmed` rechecks source identity and atomically inserts row+binding; existing same source is untouched, a different same-ID source conflicts. Missing sidecar permits existing schema-1-compatible audio-only recovery only for explicitly authorized legacy discovery or an owned capture receipt; malformed sidecar is not equivalent to absent. Default changes never call this API. Recover only stopped/publishing/failed owned reservations with coherent receipts, not arbitrary new-folder files.

```dart
// client/test/unit/data/storage_import_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_importer.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
void main() {
  test('different-root same ID and mismatched sidecar do not overwrite', () async {
    final f=StorageFixture.create(); final m=DefaultRecordingMutationCoordinator(db:f.db);
    addTearDown(() async { await m.drain(); await f.close(); });
    final old=await f.seed('fixture-collision'); await m.restoreFences();
    final before=(await f.db.getDump(old.key.dumpId))!.toJson();
    await f.audio('B',old.key.dumpId).writeAsBytes([9,8,7]);
    await f.metadata('B',old.key.dumpId).writeAsString(jsonEncode({'schemaVersion':2,'id':old.key.dumpId,'title':'Foreign'}));
    await f.audio('B','fixture-invalid').writeAsBytes([8]);
    await f.metadata('B','fixture-invalid').writeAsString(jsonEncode({'schemaVersion':2,'id':'different-id'}));
    final importer=BoundRecordingImporter(db:f.db,backend:f.backend,mutations:m);
    final preview=requireOk(await importer.preview(fileLocation('B',f.directory('B'))));
    final result=requireOk(await importer.adoptConfirmed((operationId:'fixture-import', entries:preview.entries)));
    expect(result.items.any((i)=>i.id==old.key.dumpId && i.state==ImportState.collision), isTrue);
    expect(result.items.any((i)=>i.id=='fixture-invalid' && i.state==ImportState.invalid), isTrue);
    expect((await f.db.getDump(old.key.dumpId))!.toJson(), before);
    expect(await f.audio('A',old.key.dumpId).readAsBytes(), [1,2,3]);
    expect(await f.audio('B',old.key.dumpId).readAsBytes(), [9,8,7]);
  });
}
```

- [ ] **5.5 Verify/refactor/commit:** Add success-after-stop, recorder-null/error, publication failure, DB failure, existing target collision, same-source import no-op, retained nullable manual marker fields and owned-reservation restart cases to these fixtures. Verify current legacy serializer semantics remain unchanged. Run the new tests plus existing recording-service/persistence/metadata tests. Stage the exact listed files and `git commit -m "feat(storage): pin capture destinations and guard restoration ownership"` after diff review.

## Task 6: Recoverable local deletion, live queries and mechanical caller closure

**Owner:** Ted. **Depends on:** 1–5. **Create:** `client/lib/data/storage/local_deletion_service.dart`, `storage_providers.dart`, `client/test/unit/data/local_deletion_service_test.dart`, `storage_search_test.dart`, `client/test/unit/services/storage_caller_races_test.dart`. **Modify:** `client/lib/data/local_db.dart`, `audio_storage.dart`, `manual_transcript_publication.dart`, `client/lib/main.dart`, `client/lib/services/server_transcription_service.dart`, `sync_engine.dart`, `recording_playback.dart`, `client/lib/screens/home/home_providers.dart`, `home_screen.dart`, `client/lib/screens/recording/recording_controller.dart`, `client/lib/screens/dump/dump_detail_screen.dart`, `dumps_providers.dart`. Mechanical fixture adaptations also include existing data/storage/service tests and `client/test/widget/{manual_transcript_publication_cases.dart,dump_detail_local_transcription_test.dart,dump_detail_playback_test.dart,home_screen_test.dart,recording_controller_test.dart,dumps_providers_test.dart,dumps_list_transcription_indicator_test.dart}` and `client/test/unit/screens/home/home_providers_test.dart`/`dump/dump_detail_provider_test.dart`. No selection/Settings redesign in this task.

**Interfaces:** Produces C1 `LocalDeletionService`, completed database ABI and the provider ABI below. Every existing producer moves to captured `storageKey` guards; no old ID-only destruction survives.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **6.1 RED: implement the complete mixed partial-result/retry test below.** Both file operations are real except the injected metadata-denial result. Explicit retry must use the same frozen original binding despite a current-default change.

```dart
// client/test/unit/data/local_deletion_service_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';
void main() {
  test('partial delete keeps row; explicit retry finishes original root once', () async {
    final f=StorageFixture.create(); final backend=ScriptedStorageBackend();
    final a=await f.seed('fixture-delete');
    await f.seed('fixture-active',status:'running');
    await f.audio('B',a.key.dumpId).writeAsBytes([9]);
    final m=DefaultRecordingMutationCoordinator(db:f.db);
    addTearDown(() async { await backend.drain(); await m.drain(); await f.close(); });
    await m.restoreFences();
    final service=DefaultLocalDeletionService(db:f.db,backend:backend,mutations:m);
    final preview=requireOk(await service.preview({a.key.dumpId,'fixture-active'}));
    expect(backend.componentCalls,0); // Preview/cancel has no mutation.
    backend.metadataDeleteFails=true;
    final request=(operationId:'fixture-delete-batch',targets:preview.targets);
    final first=requireOk(await service.deleteConfirmed(request));
    expect(first.items.where((i)=>i.state==DeleteState.failed),hasLength(1));
    expect(first.items.where((i)=>i.state==DeleteState.skipped),hasLength(1));
    expect(await f.audio('A',a.key.dumpId).exists(),isFalse);
    expect(await f.metadata('A',a.key.dumpId).exists(),isTrue);
    expect(await f.db.getDump(a.key.dumpId),isNotNull);
    final count=backend.componentCalls;
    final replay=requireOk(await service.deleteConfirmed(request));
    expect(replay.replayed,isTrue); expect(backend.componentCalls,count);
    final different=(operationId:request.operationId,targets:<DeleteTarget>[]);
    expect(await service.deleteConfirmed(different),isA<Fail<BulkDeletionResult>>());
    final failed=first.items.singleWhere((i)=>i.state==DeleteState.failed);
    backend.metadataDeleteFails=false;
    final done=requireOk(await service.retryConfirmed((operationId:'fixture-retry',ticketIds:[failed.ticketId!])));
    expect(done.items.single.state,DeleteState.deleted);
    expect(await f.db.getDump(a.key.dumpId),isNull);
    expect(await f.db.isRetired(a.key.dumpId),isTrue);
    expect(await f.audio('B',a.key.dumpId).readAsBytes(),[9]);
    expect(await f.db.getDump('fixture-active'),isNotNull);
  });
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/data/local_deletion_service_test.dart --concurrency=1 --reporter expanded`.

- [ ] **6.2 GREEN service:** Preview deduplicates exact IDs and returns immutable target/binding snapshots plus eligibility. Confirm transactionally persists batch identity/payload, acquires exclusive per-record admission, rechecks eligibility, persists the exact ticket, deletes audio then metadata through retained I/O and records each real result. `removed` and proven `absent` allow progress; `failed/unknown` retain the row/ticket and produce a failed outcome. Stop that item's destructive progression on uncertain audio outcome. Finish row/binding/SyncQueue removal and retired receipt only when both components are confirmed gone. Process other independent items after a failure. Repeated operation ID with identical payload returns in-flight/final result; different payload is conflict. A retry has a new batch ID but reuses frozen ticket identity; it does not allocate new target ownership.
- [ ] **6.3 RED/GREEN restart:** Reopen the temporary DB with a pending ticket before constructing import/recovery; assert no additional file deletion occurs at startup, admission is fenced, and explicit retry completes. Inject DB-finalization failure after both files disappear; retry must finalize without treating denied old-root enumeration as absence. Add permission failure, both missing, false native delete, active playback and wrong-incarnation confirmation to the result matrix. Completed receipts must exclude semantic content.
- [ ] **6.4 Mechanical DB/caller closure:** Add required `storageKey` to all mutation signatures in the database ABI. Wrap checks in the same transactions/predicates as old CAS. Replace production general upsert with task-5 atomic insert/binding. Every source below captures the key before its asynchronous work and retains admission/actual I/O:

| Producer | Exact adaptation |
|---|---|
| Server transcription `_prepareOwnership`, ordinary input/upload and recovered prerequisite reads | Acquire acceptance/recovery lease before awaited acceptance; capture its key with the existing attempt/request. All DB updates pass it. Retain original transport futures across outer timeouts; no new request on disposal/recovery. |
| `_repairCompletedSidecar`, normal completion writer, `publishManualTranscriptSidecar` | Use `RecordingAccess.runSerializedMetadataWrite(key, callback)`; callback receives pinned raw writer. Preserve latest-row, nullable request, exact manual marker, error restoration and fresh `now` acknowledgement unchanged. No second rewrite. |
| SyncEngine | Acquire sync lease before row read/audio/upload, pass key through status updates, remove empty-byte error masking. Guard each later network step after timeout/disposal; privacy query still excludes Meeting/local-only. |
| Detail title, transcript and regenerated notes | Acquire edit lease before DB write; retain it through queued publication. Keep unsaved draft/CAS behavior and existing clocks. |
| Detail player/Delete | Open through typed playback lease. After confirmation, await this route's player close, then call the same deletion service. Other playback remains busy; cancellation never closes/deletes files. |
| Recording home/controller | Replace stop-then-save split with `RecordingCoordinator.stopAndPersist`; state stays finalizing through commit. |
| Startup/providers | DB migration → app-owned mutation restore → catalog legacy bootstrap → explicitly scoped legacy/owned recovery → app repair owner/UI. Missing default disables capture but allows library/Settings. Never create a mutation registry on server-provider replacement. |

- [ ] **6.5 Define providers and migrate fakes:** In `client/lib/data/storage/storage_providers.dart` publish exact `Provider<StorageCatalog> storageCatalogProvider`, `Provider<RecordingMutationCoordinator> recordingMutationsProvider`, `Provider<RecordingAccess> recordingAccessProvider`, `Provider<RecordingCoordinator> recordingCoordinatorProvider`, `Provider<LocalDeletionService> localDeletionServiceProvider`, `Provider<RecordingImporter> recordingImporterProvider`, and `StreamProvider<DefaultFolderState> defaultFolderProvider`. Main overrides app-owned concrete values once. Keep old `audioStorageProvider` only as a locator-aware compatibility façade for callers not yet deleted during this task; before gate B it must not contain current-root read/write/delete/list behavior. Remove `deleteFile(String)` from production callers. Adapt every existing fake/fixture mechanically to captured keys and preserve old assertions rather than dropping regression cases.
- [ ] **6.6 RED/GREEN live search:** Add `watchSearchDumps` using the current escaped FTS SQL with `.watch()` instead of `.get()`, `readsFrom:{dumps}`, unchanged rank limit. `searchResultsProvider` becomes a `StreamProvider` with filters applied after 100 candidates. No post-delete manual-refresh dependency. Actual DB test below proves a same-query mutation emits, separate from widget fake streams.

```dart
// client/test/unit/data/storage_search_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../../support/storage_fixture.dart';
void main() {
  test('same-query search emits title mutation without changing query', () async {
    final f=StorageFixture.create(); addTearDown(f.close);
    final a=await f.seed('fixture-search');
    final stream=StreamIterator(f.db.watchSearchDumps('unique token'));
    addTearDown(stream.cancel);
    expect(await stream.moveNext(),isTrue); expect(stream.current,isEmpty);
    await f.db.updateDumpTitle(a.key.dumpId,storageKey:a.key,title:'unique token',now:DateTime.utc(2030));
    expect(await stream.moveNext(),isTrue); expect(stream.current.single.id,a.key.dumpId);
  });
}
```

- [ ] **6.7 RED/GREEN caller races:** Extend the existing `server_transcription_service_test.dart` fixture client, without HTTP, at actual pre-acceptance, upload and metadataWriter boundaries. Gate accepted DB completion before return, dispose/recreate service, attempt deletion, release and assert same-ID handoff and no resurrection. Gate sync read/upload before old syncing timing. Gate manual DB result then publish after another owner acknowledged; assert no second write. Add integration `storage_caller_races_test.dart` combining real temp A/B, production service, injected existing fixture client and actual raw metadata writer. Compare A input bytes, every non-timestamp metadata field, notes/audio/identity and B decoy; report inherited timestamp discrepancy separately, never normalize it. All new gates register failure-safe release/drain teardown before assertions.
- [ ] **6.8 Verify/refactor/commit:** Run all new storage tests and the existing service/manual/widget regression suites. Audit the complete call graph using `git diff` and a source search for `readBytes`, `writeMetadata`, `deleteFile`, `deleteDump`, `upsertDump`, `beginTranscriptionAttempt`, `updateTranscriptionSidecarError`; every production occurrence must be bound/guarded or removed. Stage only listed changes and `git commit -m "feat(storage): integrate guarded local deletion and bound callers"`. Backend gate B is required before any new UI action is enabled.

## Task 6 executable integration packet and ABI closure

This packet is part of task 6, supplied to its worker with the task brief. Constructors change mechanically as follows: `ServerTranscriptionService` replaces required `AudioStorage audioStorage` with required `RecordingAccess recordingAccess` and required `RecordingMutationCoordinator mutations`; all other parameters/defaults remain unchanged except the optional metadataWriter receives `BoundRecording` rather than bare String. `SyncEngine` makes the identical storage-argument replacement and retains client/connectivity/settings. `publishManualTranscriptSidecar` replaces required `AudioStorage audio` with required `RecordingAccess access` and required `RecordingKey storageKey`; revision/now/checkActive remain unchanged and metadataWriter receives `BoundRecording`. `RecordingPlaybackEngine.load` and `RecordingPlaybackController.initialize` take `AudioLocator` instead of String; the backend switches on `kind`, not `Uri.hasScheme`. Capture persistence takes its reservation explicitly: `RecordingPersistence.save(RecordingResult result, {required CaptureReservation reservation})`; no caller re-derives a destination from filename/default.

**Compilation boundary rule:** The task that changes a required signature also updates its mechanical callers in the same commit. Specifically task 5 includes the recording-only adaptations in `client/lib/screens/recording/recording_controller.dart`, `client/lib/screens/home/home_screen.dart`, `client/lib/screens/home/home_providers.dart`, `client/lib/data/storage/storage_providers.dart` and `client/lib/main.dart` necessary to construct/use the new coordinator; task 6 completes the remaining service/deletion wiring. All are Ted-owned. Do not leave calls to parameterless recorder start or unbound persistence for the next worker. Table data classes use `StorageLocationRow`, `StorageCatalogStateRow`, `RecordingBindingRow`, `CaptureReservationRow`, `LocalDeletionBatchRow`, `LocalDeletionTicketRow` to avoid clashes with C1 typedefs. Current semantic DumpRow is unchanged.

Capture admission is special: it resolves an existing same-incarnation reservation before a Dumps row exists and returns a lease with `binding == null`. Its pinned location is the reservation's location. `hasActiveCapture` includes restored native capture uses; bootstrap may mark an old reservation interrupted only after native work is proven absent/settled, not merely because a Dart object was replaced. Metadata FIFO completion waits for its own lease's actual children in a `finally` inside the serialized operation; an outer coordinator timeout releases the global scheduling wait but not the per-record FIFO or lease. Publication callbacks never reacquire that FIFO.

`DeleteTarget.id` always retains the requested ID. Missing/unresolved previews have null binding and a noneligible reason; confirmation cannot later resolve them against a newly appeared row. Failed tickets are retryOnly and have explicit retry controls rather than a permanently disabled record. `watchEligibility` combines DB status/markers/tickets and live/restored use counters. Per-operation Future settlement and ordinary DB reads alone never prove eligibility. `RecordingAccess.openPlayback` obtains `backend.playbackSource(binding)` under its lease: native code may rebuild a URI using an equivalent retained grant and the proven SAME audio document identity, without rewriting old `audioPath`. It cannot infer a parent or use the new default; filesystem playback preserves the exact file source. Batch/ticket persistence whitelists only identity, component progress and sanitized diagnostics—preview titles and semantic transcript/notes never enter completed receipts.

```dart
// client/test/unit/services/storage_caller_races_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';
import '../../support/file_recorder.dart';
import 'package:tangent/services/recording_coordinator.dart';

final class DeferredIo<T> implements IoOperation<T> {
 DeferredIo(this.id, Future<T> Function() body) { result=_run(body); }
 @override final String id;
 @override late final Future<T> result;
 final _done=Completer<void>();
 @override Future<void> get settled=>_done.future;
 Future<T> _run(Future<T> Function() body) async {
  try { return await body(); } finally { _done.complete(); }
 }
}
final class GateMetadataBackend extends ScriptedStorageBackend {
 final entered=Completer<void>(), release=Completer<void>();
 bool first=true;
 @override IoOperation<Outcome<void>> writeMetadata(BoundRecording binding,
     Map<String,dynamic> metadata,String operationId) {
  if(!first) return super.writeMetadata(binding,metadata,operationId);
  first=false; entered.complete();
  return DeferredIo(operationId,() async {
   await release.future;
   return settled(super.writeMetadata(binding,metadata,operationId));
  });
 }
}
final class FixtureClient extends Fake implements TranscriptionClient {
 final uploads=<List<int>>[]; int enqueues=0;
 @override Future<String> createDump({required String id,required String mode,
  required int durationSeconds,required String title,required DateTime createdAt}) async=>id;
 @override Future<void> uploadAudio({required String dumpId,required List<int> audioBytes,
  String filename='recording.opus',String mimeType='audio/ogg'}) async { uploads.add(List.of(audioBytes)); }
 @override Future<TranscriptionJobSnapshot> enqueueTranscription(String dumpId,
  {required String requestId,String model='large-v3'}) async {
  enqueues++; return TranscriptionJobSnapshot(id:'fixture-job',requestId:requestId,
   dumpId:dumpId,status:'queued',model:model);
 }
 @override Stream<JobEvent> streamJob(String jobId,{Duration maxWait=const Duration(minutes:30)}) async* {
  yield const JobEvent('running',{});
  yield const JobEvent('completed',{'transcript':'new synthetic words'});
 }
}
void main() {
 test('A survives default B through publication, edit, DB reopen and local deletion',() async {
  final f=StorageFixture.create(); final backend=GateMetadataBackend();
  final a=await f.seed('fixture-flow',status:'completed');
  await f.audio('B',a.key.dumpId).writeAsBytes([9,9]);
  await f.metadata('B',a.key.dumpId).writeAsString('unrelated');
  final m=DefaultRecordingMutationCoordinator(db:f.db);
  final access=BoundRecordingAccess(db:f.db,backend:backend,mutations:m);
  final client=FixtureClient(); var ids=0;
  final catalog=SqliteStorageCatalog(db:f.db,backend:backend,mutations:m,
   stagingDirectory:f.directory('stage'),idFactory:()=> 'fixture-choice-${ids++}',
   now:()=>DateTime.utc(2030),canChooseDefault:true);
  final service=ServerTranscriptionService(client:client,db:f.db,recordingAccess:access,
   mutations:m,requestIdFactory:()=> 'fixture-request',now:()=>DateTime.utc(2030));
  var serviceDisposed=false;
  void closeService() { if(!serviceDisposed) { service.dispose(); serviceDisposed=true; } }
  addTearDown(() async {
   if(!backend.release.isCompleted) backend.release.complete();
   closeService(); await backend.drain(); await m.drain(); await f.close();
  });
  await m.restoreFences(unsettled:await backend.unsettledUses());
  requireOk(await catalog.bootstrapLegacyBindings(filesystemLegacyDirectory:f.directory('A')));
  final completion=service.transcribeDump(a.key.dumpId);
  await backend.entered.future;
  final before=await catalog.watchDefault().first;
  backend.choice=Ok(fileLocation('B',f.directory('B')));
  final candidate=requireOk(await catalog.chooseFolderCandidate())!;
  requireOk(await catalog.commitDefault(candidate,expectedRevision:before.revision));
  final recorder=FileRecorder(); addTearDown(recorder.dispose);
  final captures=DefaultRecordingCoordinator(db:f.db,catalog:catalog,backend:backend,
   mutations:m,recorder:recorder,now:()=>DateTime.utc(2030));
  final bReservation=requireOk(await captures.start(mode:'meeting'));
  final b=requireOk(await captures.stopAndPersist())!;
  expect(b.audioPath,f.audio('B',b.id).path);
  expect(b.id,bReservation.key.dumpId);
  final bRow=b.toJson(); final bMetadata=await f.metadata('B',b.id).readAsString();
  final deletion=DefaultLocalDeletionService(db:f.db,backend:backend,mutations:m);
  final blocked=requireOk(await deletion.preview({a.key.dumpId}));
  final skipped=requireOk(await deletion.deleteConfirmed((operationId:'fixture-blocked',targets:blocked.targets)));
  expect(skipped.items.single.state,DeleteState.skipped);
  backend.release.complete(); await completion; await m.drain();
  expect(client.uploads,[[1,2,3]]); expect(client.enqueues,1);
  final edit=requireOk(await m.acquire(a.key.dumpId,UseKind.edit,expectedIncarnation:a.key.incarnation));
  try {
   await f.db.updateDumpTitle(a.key.dumpId,storageKey:a.key,title:'Edited in A',now:DateTime.utc(2030));
   await access.runSerializedMetadataWrite(a.key,(writer) async {
    final latest=(await f.db.getDump(a.key.dumpId))!;
    await writer.write(dumpMetadata(latest));
   });
  } finally { await edit.close(); }
  expect(await f.metadata('A',a.key.dumpId).readAsString(),contains('Edited in A'));
  closeService(); await backend.drain(); await m.drain(); await f.reopen();
  final restored=DefaultRecordingMutationCoordinator(db:f.db);
  addTearDown(restored.drain);
  await restored.restoreFences(unsettled:await backend.unsettledUses());
  expect((await f.db.boundRecording(a.key.dumpId))!.location.directory.path,f.directory('A'));
  final after=DefaultLocalDeletionService(db:f.db,backend:backend,mutations:restored);
  final preview=requireOk(await after.preview({a.key.dumpId}));
  expect(requireOk(await after.deleteConfirmed((operationId:'fixture-final',targets:preview.targets))).items.single.state,DeleteState.deleted);
  expect(await f.audio('A',a.key.dumpId).exists(),isFalse);
  expect(await f.metadata('A',a.key.dumpId).exists(),isFalse);
  expect(await f.audio('B',a.key.dumpId).readAsBytes(),[9,9]);
  expect(await f.metadata('B',a.key.dumpId).readAsString(),'unrelated');
  expect((await f.db.getDump(b.id))!.toJson(),bRow);
  expect(await f.audio('B',b.id).readAsBytes(),[1,2,3]);
  expect(await f.metadata('B',b.id).readAsString(),bMetadata);
 });
}
```

This fixture client does not construct any HTTP client; unexpected API calls fail through Fake. The fixed clock is test determinism, not a production timestamp workaround. Add the existing late-acceptance and nullable/manual-marker race cases with the same captured-key wiring; retain their actual pre-commit/after-commit barriers instead of replacing them with this publication-only case. Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/services/storage_caller_races_test.dart --concurrency=1 --reporter expanded` before backend gate B.

## Gate B: independent backend verification before UI

- [ ] **B.1 Sol static:** Read the complete tasks 1–6 diff at one immutable commit and all production callers; inspect B1–B7 closures, literal legacy mapping, SQL CAS/fence predicates, actual-I/O lifetime, no second publication and no server changes. Record Critical/Important findings with source lines in `backend-sol-review.md` under the feature SDD directory in the later execution lane.
- [ ] **B.2 Zoe executable:** Independently run the new fixture suites plus existing data/recording/sync/transcription/manual/provider suites; run the native JVM policy/lifetime tests. Force exact late acceptance, native-result-before-settled, partial deletion and restart interleavings. Record commands, counts, exit codes and assertion polarity in `backend-zoe-review.md`. Do not merely rerun Ted's happy paths.
- [ ] **B.3 Controller gate:** Both reviews must have zero unresolved new Critical/Important findings. Return fixes to Ted, re-review exact changed commit, then freeze the backend constructor/provider contract for Zoe. The pre-existing paused timestamp defect remains explicitly open; no full timestamp-parity claim is allowed. No phone/build installation permission follows from passing this gate.

## Task 7: Stable Dumps selection and confirmation/results UI

**Owner:** Zoe. **Depends on:** gate B. **Create:** `client/lib/screens/dump/dump_selection_controller.dart`, `client/test/unit/screens/dump/dump_selection_controller_test.dart`, `client/test/widget/dumps_selection_test.dart`. **Modify:** `client/lib/screens/dump/dumps_list_screen.dart`, `dumps_providers.dart`, `dump_detail_screen.dart` presentation only. Backend APIs are frozen; changes require Ted/controller review rather than local reinterpretation.

**Interfaces:** Consumes C1/provider ABI. Produces `DumpSelectionController()` extending `StateNotifier<DumpSelectionState>` with `apply(PresentedDumpResults results, Map<String,Eligibility> eligibility)`, `enter(String id)`, `toggle(String id)`, `toggleAll()`, `cancel()`. Add `Provider<AsyncValue<PresentedDumpResults>> presentedDumpsProvider` and `StreamProvider<Map<String,Eligibility>> deletionEligibilityProvider`; `presentedDumpsProvider` adapts the existing normal/search streams and increments generation on raw search text or either filter change, not on ordinary row updates. Add optional `DumpsListScreen({super.key, void Function(BuildContext,DumpRow)? onOpenDump})` for an explicit navigation test seam; production default retains existing navigation.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **7.1 RED: add the actual selection-state test.** Stable IDs, off-screen membership, query epoch and disabled status—not tile mounting—determine selection.

```dart
// client/test/unit/screens/dump/dump_selection_controller_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dump_selection_controller.dart';
DumpRow viewRow(String id) => DumpRow(id:id,createdAt:DateTime.utc(2030),updatedAt:DateTime.utc(2030),
 mode:'brain_dump',durationSeconds:3,title:id,audioPath:'/synthetic/$id.opus',audioSizeBytes:3,
 syncStatus:'local_only',syncAttempts:0,transcriptionStatus:'not_transcribed',transcriptionAttempt:0);
void main() {
 test('selection keeps IDs but never adds arrivals or restores stale scope', () {
  final c=DumpSelectionController(); addTearDown(c.dispose);
  final rows=List.generate(120,(i)=>viewRow('fixture-$i'));
  final eligible={for(final r in rows) r.id:Eligibility.eligible};
  c.apply((scopeKey:'all',generation:1,settled:true,rows:rows,limit:null),eligible);
  c.enter('fixture-0'); c.toggleAll(); expect(c.state.selectedIds,hasLength(120));
  c.apply((scopeKey:'all',generation:1,settled:true,rows:[viewRow('fixture-new'),...rows.reversed],limit:null),
    {...eligible,'fixture-new':Eligibility.eligible});
  expect(c.state.selectedIds,hasLength(120)); expect(c.state.selectedIds, isNot(contains('fixture-new')));
  c.apply((scopeKey:'all',generation:1,settled:true,rows:rows.skip(1).toList(),limit:null),
    {...eligible,'fixture-1':Eligibility.nonterminal});
  expect(c.state.selectedIds, isNot(contains('fixture-0')));
  expect(c.state.selectedIds, isNot(contains('fixture-1')));
  c.apply((scopeKey:'search',generation:2,settled:false,rows:<DumpRow>[],limit:100),eligible);
  expect(c.state.selectedIds,isEmpty);
  c.apply((scopeKey:'all',generation:1,settled:true,rows:rows,limit:null),eligible);
  expect(c.state.scopeKey,'search'); expect(c.state.selectedIds,isEmpty);
  c.cancel(); expect(c.state.active,isFalse);
 });
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/unit/screens/dump/dump_selection_controller_test.dart --concurrency=1 --reporter expanded`.

- [ ] **7.2 GREEN state reducer:** Reject older generation before any mutation. Scope/generation change clears selection immediately (zero-selected mode may remain active); unsettled same-scope results do not prune against a temporary empty list. Settled results intersect selection with present eligible IDs. `toggleAll` uses all current eligible returned rows, clears if already all selected and never automatically enrolls future arrivals. Use immutable copied sets/lists.

```dart
// Pure pruning helper for the controller, not index-based selection.
Set<String> retainedSelection(Set<String> selected, PresentedDumpResults results,
    Map<String,Eligibility> eligibility) => Set.unmodifiable(
  selected.intersection(results.rows.where((r)=>eligibility[r.id]==Eligibility.eligible)
    .map((r)=>r.id).toSet()));
```

- [ ] **7.3 RED widget behavior:** Add real widget tests with a controlled presented snapshot and no network/plugin. Use row keys `dump-row-<id>`, bubble keys `dump-select-<id>`, toolbar keys `selection-cancel`, `selection-all`, `selection-delete`, and dialog keys `local-delete-confirm`, `local-delete-cancel`. Navigation seam counts normal opens. Example below uses current source's real DumpRow type and explicit providers; copy `viewRow` from the preceding test into `client/test/support/dump_view_fixture.dart` and import that file in both tests (no test-file imports).

```dart
// client/test/widget/dumps_selection_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import '../support/dump_view_fixture.dart';
void main() {
 testWidgets('long press and left bubble toggle without navigating; Cancel is safe',(tester) async {
  final rows=[viewRow('fixture-a'),viewRow('fixture-b')]; var opens=0;
  await tester.pumpWidget(ProviderScope(overrides:[
   presentedDumpsProvider.overrideWithValue(AsyncData((scopeKey:'all',generation:1,settled:true,rows:rows,limit:null))),
   deletionEligibilityProvider.overrideWith((_)=>Stream.value({'fixture-a':Eligibility.eligible,'fixture-b':Eligibility.eligible})),
  ],child:MaterialApp(home:DumpsListScreen(onOpenDump:(_,__)=>opens++))));
  await tester.pump(); await tester.pump(const Duration(milliseconds:1));
  await tester.tap(find.byKey(const ValueKey('dump-row-fixture-a'))); expect(opens,1);
  await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a'))); await tester.pump();
  expect(find.byKey(const ValueKey('dump-select-fixture-a')),findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('dump-row-fixture-b'))); await tester.pump(); expect(opens,1);
  await tester.tap(find.byKey(const ValueKey('selection-all'))); await tester.pump();
  final button=tester.widget<IconButton>(find.byKey(const ValueKey('selection-delete')));
  expect(button.onPressed,isNull);
  await tester.tap(find.byKey(const ValueKey('selection-cancel'))); await tester.pump();
  expect(find.byKey(const ValueKey('dump-select-fixture-a')),findsNothing);
  await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
 });
}
```

- [ ] **7.4 GREEN rendering:** Preserve both filter rows and status pills. Add circular `Checkbox(shape:CircleBorder())` or equivalent accessible controls with a minimum 48 logical-pixel target, selected/disabled semantics and reason text/tooltips. Top action is an `IconButton` keyed `selection-delete`, disabled when zero, unsettled or a batch is active. Select all exposes checked/mixed/unchecked semantics and truthful `returned results` scope under the 100-candidate cap. Intercept Back only while selection mode is active; normal Back retains routing.
- [ ] **7.5 RED/GREEN confirmed deletion:** Inject a counting `LocalDeletionService` fake for widget tests. Preview is allowed, but Cancel must make zero `deleteConfirmed`/`retryConfirmed` calls; Confirm calls exactly once with a copied preview, despite double taps. Dialog text: `Delete N local recordings?` and `Local audio, transcripts/notes, and metadata will be removed. Server copies are not deleted and server jobs are not canceled.` Cancel is the safe default. Before opening a delayed preview, verify its source scope/generation is still current; discard obsolete previews. After confirmation, do not expand targets if search/filter changes.
Add `client/test/widget/dumps_selection_confirmation_test.dart` to task 7's create/test/stage set. Confirmation buttons are `TextButton` Cancel and `FilledButton` Confirm with the named keys. The dialog keeps a one-use resolved latch so a stale second callback cannot pop another route.

```dart
// client/test/widget/dumps_selection_confirmation_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import '../support/dump_view_fixture.dart';
class CountingDeletion extends Fake implements LocalDeletionService {
 int deletes=0; ConfirmedDeletion? received;
 @override Future<Outcome<DeletionPreview>> preview(Set<String> ids) async => Ok((targets:[
  for(final id in ids) (id:id,binding:(key:(dumpId:id,incarnation:'fixture-incarnation'),
   location:(id:'A',label:'A',directory:(kind:'file',path:'/synthetic',treeUri:'',authority:'',documentId:'')),
   audio:(kind:'file',value:'/synthetic/$id.opus'),metadataName:'$id.meta.json'),
   title:id,eligibility:Eligibility.eligible,retryTicketId:null)
 ]));
 @override Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request) async {
  deletes++; received=request;
  return Ok((replayed:false,items:[for(final target in request.targets)
   (id:target.id,state:DeleteState.deleted,
    audio:(state:ComponentState.removed,problem:null),metadata:(state:ComponentState.removed,problem:null),
    ticketId:null,problem:null)]));
 }
}
void main() {
 testWidgets('confirmation Cancel is inert and repeated Confirm is one batch',(tester) async {
  final deletion=CountingDeletion(); final rows=[viewRow('fixture-a')];
  await tester.pumpWidget(ProviderScope(overrides:[
   localDeletionServiceProvider.overrideWithValue(deletion),
   presentedDumpsProvider.overrideWithValue(AsyncData((scopeKey:'all',generation:1,settled:true,rows:rows,limit:null))),
   deletionEligibilityProvider.overrideWith((_)=>Stream.value({'fixture-a':Eligibility.eligible})),
  ],child:const MaterialApp(home:DumpsListScreen())));
  await tester.pump(); await tester.pump(const Duration(milliseconds:1));
  await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a'))); await tester.pump();
  await tester.tap(find.byKey(const ValueKey('selection-delete'))); await tester.pump(const Duration(milliseconds:250));
  await tester.tap(find.byKey(const ValueKey('local-delete-cancel'))); await tester.pump(const Duration(milliseconds:250));
  expect(deletion.deletes,0);
  await tester.tap(find.byKey(const ValueKey('selection-delete'))); await tester.pump(const Duration(milliseconds:250));
  final confirm=tester.widget<FilledButton>(find.byKey(const ValueKey('local-delete-confirm'))).onPressed!;
  confirm(); confirm(); await tester.pump(const Duration(milliseconds:250));
  expect(deletion.deletes,1); expect(deletion.received!.targets.single.id,'fixture-a');
  expect(find.byType(DumpsListScreen),findsOneWidget);
  await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
 });
}
```

- [ ] **7.6 GREEN results/retry:** Render deleted/failed/skipped totals computed from item outcomes. Identify partial failures and component progress. Failed-ticket retry has its own count confirmation and calls `retryConfirmed` with exact ticket IDs and a new operation ID; do not clear the durable fence to retry. A replayed result is not a new deletion toast. Late results never restore selection in a changed scope. Detail uses the same result presentation and already-integrated boundary.
- [ ] **7.7 Verify/refactor/commit:** Run the unit/widget tests plus existing Dumps provider/pill and detail tests. Add narrow viewport 360×640 and 280×640, accessible labels/tap targets, off-screen Select all, disabled rows, confirmation Cancel/double tap, filter/search changes and late-response checks. Do not `pumpAndSettle` with running progress indicators; use bounded pumps. Stage exact UI/test files and `git commit -m "feat(ui): add guarded Dumps multiselection and local deletion"` after review.

## Task 8: Settings Default save folder UI

**Owner:** Zoe. **Depends on:** B, 7. **Create:** `client/lib/screens/settings/storage_settings_section.dart`, `client/test/widget/storage_settings_test.dart`. **Modify:** `client/lib/screens/settings/settings_screen.dart` to render the new local section; no changes to server credential/model values or their save behavior.

**Interfaces:** `const StorageSettingsSection({super.key})` consumes C1 `StorageCatalog` through `storageCatalogProvider` and committed `defaultFolderProvider`. The section is renderable/testable without a server connection.

<!-- CONTRACT-C1-BEGIN -->
```dart
// client/lib/data/storage/storage_contract.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode { denied, unavailable, absent, invalid, conflict, staleRevision, busy, unresolved, retired, fenced, wrongIncarnation, unsupported, persistence, io, unknown, interrupted }
typedef StorageProblem = ({ProblemCode code, String message});
sealed class Outcome<T> { const Outcome(); }
final class Ok<T> extends Outcome<T> { const Ok(this.value); final T value; }
final class Fail<T> extends Outcome<T> { const Fail(this.problem); final StorageProblem problem; }
final class StorageFault implements Exception { const StorageFault(this.problem); final StorageProblem problem; @override String toString() => '${problem.code.name}: ${problem.message}'; }
typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({String kind, String path, String treeUri, String authority, String documentId});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({String? defaultLocationId, int revision, int bootstrapVersion, String? legacyAnchorJson, String? candidateJson});
typedef RecordingBinding = ({RecordingKey key, String originalAudioJson, String? locationId, String metadataName, String? legacyAnchorJson, bool resolved});
typedef BoundRecording = ({RecordingKey key, StorageLocation location, AudioLocator audio, String metadataName});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({List<String> unresolvedIds, List<StorageProblem> problems});
typedef DefaultFolderState = ({StorageLocation? location, int revision, bool available, bool canChooseDefault, StorageProblem? problem});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});
enum CapturePhase { idle, reserved, recording, stopped, publishing, failed, committed, interrupted }
typedef CaptureReservation = ({String id, RecordingKey key, StorageLocation location, String stagingPath, String mode, DateTime startedAt, CapturePhase phase});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});
typedef RecordingLifecycleState = ({CapturePhase phase, CaptureReservation? reservation, StorageProblem? problem});
enum UseKind { read, playback, acceptance, sync, edit, publication, recovery, capture, deletion }
enum Eligibility { eligible, busy, nonterminal, syncing, publicationPending, unresolved, retired, deleting, missing, denied, retryOnly }
enum RecordingComponent { audio, metadata }
enum ComponentState { pending, removed, absent, failed, unknown }
typedef ComponentResult = ({ComponentState state, StorageProblem? problem});
enum TicketState { pending, failed, completed }
typedef DeletionTicket = ({String id, String operationId, BoundRecording binding, ComponentResult audio, ComponentResult metadata, TicketState state});
typedef DeleteTarget = ({String id, BoundRecording? binding, String title, Eligibility eligibility, String? retryTicketId});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});
enum DeleteState { deleted, failed, skipped }
typedef DeletionItemResult = ({String id, DeleteState state, ComponentResult audio, ComponentResult metadata, String? ticketId, StorageProblem? problem});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});
enum ImportState { adopted, alreadyKnown, collision, retired, invalid, unavailable }
typedef ImportedEntry = ({String id, StorageLocation source, AudioLocator audio, int sizeBytes, DateTime modifiedAt, Map<String,dynamic>? metadata, StorageProblem? problem});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({String id, ImportState state, StorageProblem? problem});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({List<String> recoveredIds, List<String> retainedReservationIds, List<StorageProblem> problems});
typedef PresentedDumpResults = ({String scopeKey, int generation, bool settled, List<DumpRow> rows, int? limit});
typedef DumpSelectionState = ({bool active, Set<String> selectedIds, String scopeKey, int generation});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});
abstract interface class IoOperation<T> { String get id; Future<T> get result; Future<void> get settled; }
abstract interface class UseLease { RecordingKey get key; BoundRecording? get binding; Future<void> close(); }
abstract interface class AudioReadLease { RecordingKey get key; Future<Uint8List> read(); Future<void> close(); }
abstract interface class PlaybackLease { RecordingKey get key; AudioLocator get source; RecordingPlaybackEngine get engine; Future<void> close(); }
abstract interface class MetadataPublicationAccess { BoundRecording get binding; Future<void> write(Map<String,dynamic> metadata); }
abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({required String filesystemLegacyDirectory, String? frozenAnchorJson});
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(String token, StorageLocation location);
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  // Transitional phase A only; REMOVE this old method in phase B.
  IoOperation<Outcome<PublishedCapture>> publishCapture(CaptureReservation reservation, Map<String,dynamic> metadata);
  IoOperation<CapturePreparationResult> prepareCapture(CaptureReservation reservation, String metadataJson, String audioSha256, String operationId, {required bool observeOnly});
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(CaptureReservation reservation, PreparedCapture preparation);
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
  IoOperation<Outcome<void>> writeMetadata(BoundRecording binding, Map<String,dynamic> metadata, String operationId);
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding, RecordingComponent component, String operationId);
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(StorageLocation location);
  Future<void> drain();
}
abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(String dumpId, UseKind kind, {String? expectedIncarnation, String? retryTicketId});
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String,Eligibility>> watchEligibility();
  Future<void> drain();
}
abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({required String filesystemLegacyDirectory});
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate, {required int expectedRevision});
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}
abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(RecordingKey key, RecordingPlaybackEngine engine);
  Future<T> runSerializedMetadataWrite<T>(RecordingKey key, Future<T> Function(MetadataPublicationAccess access) operation);
}
abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}
abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(ConfirmedDeletion request);
  Future<Outcome<BulkDeletionResult>> retryConfirmed(ConfirmedDeletionRetry request);
  Stream<Map<String,Eligibility>> watchEligibility();
}
abstract interface class RecordingImporter {
  Future<Outcome<ImportPreview>> preview(StorageLocation source);
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection);
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures();
}
abstract interface class StorageDatabaseOperations {
  Future<BoundRecording?> boundRecording(String id);
  Future<void> bindRecording(BoundRecording binding);
  Future<bool> isRetired(String id);
  Future<bool> mutationAllowed(RecordingKey key);
  Future<Outcome<DeletionTicket>> claimLocalDeletion(String operationId, DeleteTarget target);
  Future<void> recordDeletionComponent(String ticketId, RecordingComponent component, ComponentResult result);
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
```
<!-- CONTRACT-C1-END -->

- [ ] **8.1 RED: add the concrete Cancel/desktop test below.** The fake is UI-only; tasks 4–6 prove real persistence. No server/phone/plugin call occurs.

```dart
// client/test/widget/storage_settings_test.dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/settings/storage_settings_section.dart';
final class CancelCatalog extends Fake implements StorageCatalog {
 int picks=0, commits=0;
 @override Future<Outcome<FolderCandidate?>> chooseFolderCandidate() async {
  picks++; return const Ok<FolderCandidate?>(null);
 }
 @override Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate,{required int expectedRevision}) async {
  commits++; return const Fail<DefaultFolderState>((code:ProblemCode.invalid,message:'Unexpected commit'));
 }
}
void main() {
 for(final canChoose in [true,false]) {
  testWidgets('committed label survives Cancel; picker capability=$canChoose',(tester) async {
   final catalog=CancelCatalog();
   final location=(id:'old',label:'Original recordings',directory:(kind:'file',path:r'C:\synthetic\old',treeUri:'',authority:'',documentId:''));
   final state=(location:location,revision:7,available:true,canChooseDefault:canChoose,problem:null);
   await tester.pumpWidget(ProviderScope(overrides:[
    storageCatalogProvider.overrideWithValue(catalog),
    defaultFolderProvider.overrideWith((_)=>Stream.value(state)),
   ],child:const MaterialApp(home:Scaffold(body:StorageSettingsSection()))));
   await tester.pump(); await tester.pump(const Duration(milliseconds:1));
   expect(find.text('Original recordings'),findsOneWidget);
   if(canChoose) {
    await tester.tap(find.byKey(const ValueKey('change-default-folder')));
    await tester.pump(); await tester.pump(const Duration(milliseconds:1));
    expect(catalog.picks,1); expect(catalog.commits,0);
    expect(find.text('Original recordings'),findsOneWidget);
   } else {
    expect(find.byKey(const ValueKey('change-default-folder')),findsNothing);
    expect(catalog.picks,0);
   }
   await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
  });
 }
}
```

Run `~/AppData/Local/flutter/bin/flutter.bat test test/widget/storage_settings_test.dart --concurrency=1 --reporter expanded`.

- [ ] **8.1b RED actual Settings host (audit Z1):** Add a regression in `client/test/widget/storage_settings_test.dart` mounting the real `SettingsScreen`, not only `StorageSettingsSection`. Resolve fake local/secure settings with a saved nonempty server URL, override the canonical storage providers, and hold fake `getServerInfo()` on a controlled unresolved future. With bounded pumps, assert that the committed folder label (and, separately, unavailable-folder diagnostic) and `change-default-folder` action render while server info is still pending; tap Change folder and prove the fake catalog is reached. The old whole-screen `_loaded` spinner must cause the RED failure. Release the controlled future and unmount in failure-safe teardown. Retain the isolated Cancel/desktop test; it is not a substitute for this host regression.
- [ ] **8.2 GREEN local section and host:** Render Storage independently of server-info completion in the real `SettingsScreen`; limit server loading/error indicators to the server subsection while preserving server values and save behavior. Show `Storage`, `Default save folder`, committed human-readable label, availability diagnostic and `Changes apply to new recordings only. Existing recordings stay in their original folders.` Android Change folder invokes candidate selection then `commitDefault(candidate, expectedRevision: capturedRevision)`. Cancel does nothing. Disable duplicate clicks; after each await check mounted before continuing UI-owned confirmation/commit. Never optimistically change the label before committed state arrives. Native picker capability false means read-only desktop display, not a fallback path text field.
- [ ] **8.3 RED/GREEN error states:** Extend `CancelCatalog` with a chosen candidate and explicit Fail values for denied, staleRevision, busy and persistence. Each shows an actionable message with the old label retained. A delayed result after unmount makes no follow-up commit. A successful fake commit must emit a new committed state before the label changes; independently exercise the real catalog restart test. Missing default does not hide the entire Settings/library; capture alone is disabled.
- [ ] **8.4 Integration/refactor/commit:** Run new Settings, selection and existing settings-store/server-connection tests. No folder choice calls `SettingsStore.save` or modifies server configuration. Preserve narrow layout; use wrapped label text instead of exposing a raw editable URI. Stage the new section/test and Settings screen, then `git diff --cached --check && git commit -m "feat(ui): expose Android default recording folder safely"`.

## Gate I: independent integration review

- [ ] **I.1 Sol static:** Review tasks 7–8 plus integrated backend at one immutable commit. Check exact confirmed targets, replay/partial reporting, query generations, old paths/grants, no blind import, no mutation bypass, no timestamp acknowledgement fix and no scope expansion. Inspect generated files, dependency changes and all source diff against the planning HEAD.
- [ ] **I.2 Ted executable:** Independently exercise disposable A→B→restart read/transcribe/edit/repair/delete with the production bound access, service fake transport, DB and filesystem. Run new widget tests, including the real SettingsScreen pending-server regression from 8.1b, same-query live DB tests and gated caller races. Test missing default with usable old recording, failed save staging retention and explicit interrupted-delete retry. Record results in `integration-ted-review.md`; Sol uses `integration-sol-review.md`. No live files, devices or server processes.
- [ ] **I.3 Controller gate:** Zero unresolved new Critical/Important findings in both reviews. Implementation owners fix their lanes and reviewers verify new commits; only then proceed to G. The paused known timestamp issue remains excluded from this feature's repair scope and explicitly disclosed, not silently marked green.

## Gate G: actual test, analyzer, native and debug APK evidence

These commands are for later authorized execution, not this plan-authoring lane. Workdir is explicit. Run full commands without output-tail pipelines and record exit code even when failing. A green parser check of this document does not satisfy these gates.

From the worktree `client` directory:

```sh
set -e
~/AppData/Local/flutter/bin/flutter.bat test --concurrency=1 --reporter expanded
~/AppData/Local/flutter/bin/flutter.bat analyze
~/AppData/Local/flutter/bin/flutter.bat build apk --debug
```

From `client/android`, use an already verified JDK/SDK environment; if missing, report the blocker instead of changing machine defaults:

```sh
./gradlew.bat :app:testDebugUnitTest :app:lintDebug :app:assembleDebug --console=plain
```

From repository root:

```sh
set -e
git diff --check
git status --short --untracked-files=all
git diff --exit-code ac8696a9bf399c502cedec377011b871b3440236 -- server
```

APK artifact: `~/Documents/ADH2/.worktrees/durable-transcription-recovery/client/build/app/outputs/flutter-apk/app-debug.apk`.

Record its actual SHA-256 using the normal approved hash tool, e.g. `certutil.exe -hashfile client/build/app/outputs/flutter-apk/app-debug.apk SHA256` from repository root. Record APK byte size, test counts, failures and native XML result locations under `client/build/app/test-results/testDebugUnitTest/` (confirm the actual Gradle buildDir before citing a result path). Do not invent a hash, installed version or physical acceptance. Recheck generated plugin registrants after the LAST Flutter command; restore only unrelated generated noise after inspecting exact paths, never broadly reset feature changes. No installation or live-data action is in this plan.

If any required tool/dependency is unavailable, G is BLOCKED, not skipped/pass. No model/provider/config fallback. No server suite command is required because server code is unchanged and server commands are excluded; client transport fakes and a zero server diff are the relevant proof here.

## Coverage map and completion conditions

| Approved requirement | Implementation and decisive evidence |
|---|---|
| §1 normal tap/long-press, bubbles, count, Select all, zero, Back/Cancel | 7.1–7.7 controller and widget fixtures |
| §1 stable IDs, arrivals/reorder, hidden/off-screen scope, search cap, late replies | 6.6 watched search; 7.1, 7.2, 7.5 and B7 |
| §1 disabled active rows/publication and accessibility/narrow layout | 3 admission; 6 eligibility; 7 widgets; gates B/I |
| §2 exact confirmation, Cancel, deduplication, local-only wording | 6.1–6.3 batch ABI; 7.5–7.6, detail adaptation |
| §2 original locations, no resurrection, partial failure/retry, search refresh | 2, 3, 6, real A/B fixture and retirement/restart tests |
| §3 label/picker, arbitrary direct root, retained legacy child mapping | 2 native policy; 4 bootstrap; 8 local section |
| §3 validation/default atomicity/cancellation/restart/grants | 4 candidate/default state machine and failing-commit fixture |
| §3 future-only change, old access/repair, pinning and staging retention | 3, 4, 5, all caller adapters in 6 |
| §3 missing/revoked roots and no unrelated import/ID overwrite | 2 typed errors; 4 unresolved anchors; 5 source-bound import |
| §4 all settled architectural choices, ownership and timestamp invariants | C1, schema/DB ABI, tasks 1–6, gates B/I |
| §5 RED/GREEN, real DB/FS, native policy, regression/analyzer/APK | Every task's focused cycle; B, I, G |
| §5 physical permission separation and §6 exclusions | Global Constraints and all gates; no phone/server/installation commands |
| Sol B1 | 1/2/4/6 immutable binding and entire locator-aware caller graph |
| Sol B2 | 4 candidate commit/reservation; 5 stop-through-commit staging |
| Sol B3 | 3 actual-lifetime leases/FIFO; 6 acceptance/sync/edit/playback integration |
| Sol B4 | 2 native false delete/type/permission/ownership and filesystem fixtures |
| Sol B5 | 3 tickets/retirement; 6 partial outcomes, explicit retry, queue/FTS finalize |
| Sol B6 | 4 no import on default; 5 atomic collision-safe adoption and owned recovery |
| Sol B7 | 6 live bounded search; 7 selection scope; 8 desktop read-only setting |

Completion requires all eight task deliverables, both independent-review gates, real G evidence and a controller handoff. No worker may claim Task 7 timestamp parity, installation or physical acceptance. The authoritative specification already settles architecture; the controller reviews this plan's implementation contract before dispatch. Any contradiction discovered in execution stops the affected lane for controller resolution rather than silently changing scope.
