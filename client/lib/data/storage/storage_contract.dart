// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/recording_playback.dart';

enum ProblemCode {
  denied,
  unavailable,
  absent,
  invalid,
  conflict,
  staleRevision,
  busy,
  unresolved,
  retired,
  fenced,
  wrongIncarnation,
  unsupported,
  persistence,
  io,
  unknown,
  interrupted
}

typedef StorageProblem = ({ProblemCode code, String message});

sealed class Outcome<T> {
  const Outcome();
}

final class Ok<T> extends Outcome<T> {
  const Ok(this.value);
  final T value;
}

final class Fail<T> extends Outcome<T> {
  const Fail(this.problem);
  final StorageProblem problem;
}

final class StorageFault implements Exception {
  const StorageFault(this.problem);
  final StorageProblem problem;
  @override
  String toString() => '${problem.code.name}: ${problem.message}';
}

typedef RecordingKey = ({String dumpId, String incarnation});
typedef DirectoryRef = ({
  String kind,
  String path,
  String treeUri,
  String authority,
  String documentId
});
typedef AudioLocator = ({String kind, String value});
typedef StorageLocation = ({String id, DirectoryRef directory, String label});
typedef StorageCatalogState = ({
  String? defaultLocationId,
  int revision,
  int bootstrapVersion,
  String? legacyAnchorJson,
  String? candidateJson
});
typedef RecordingBinding = ({
  RecordingKey key,
  String originalAudioJson,
  String? locationId,
  String metadataName,
  String? legacyAnchorJson,
  bool resolved
});
typedef BoundRecording = ({
  RecordingKey key,
  StorageLocation location,
  AudioLocator audio,
  String metadataName
});
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
typedef BootstrapResult = ({
  List<String> unresolvedIds,
  List<StorageProblem> problems
});
typedef DefaultFolderState = ({
  StorageLocation? location,
  int revision,
  bool available,
  bool canChooseDefault,
  StorageProblem? problem
});
typedef FolderCandidate = ({String token, StorageLocation location});
typedef ProbeReceipt = ({List<AudioLocator> owned, bool cleaned});

enum CapturePhase {
  idle,
  reserved,
  recording,
  stopped,
  publishing,
  failed,
  committed,
  interrupted
}

typedef CaptureReservation = ({
  String id,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  String mode,
  DateTime startedAt,
  CapturePhase phase
});
typedef PublishedCapture = ({BoundRecording binding, int sizeBytes});
typedef RecordingLifecycleState = ({
  CapturePhase phase,
  CaptureReservation? reservation,
  StorageProblem? problem
});

enum UseKind {
  read,
  playback,
  acceptance,
  sync,
  edit,
  publication,
  recovery,
  capture,
  deletion
}

enum Eligibility {
  eligible,
  busy,
  nonterminal,
  syncing,
  publicationPending,
  unresolved,
  retired,
  deleting,
  missing,
  denied,
  retryOnly
}

enum RecordingComponent { audio, metadata }

enum ComponentState { pending, removed, absent, failed, unknown }

typedef ComponentResult = ({ComponentState state, StorageProblem? problem});

enum TicketState { pending, failed, completed }

typedef DeletionTicket = ({
  String id,
  String operationId,
  BoundRecording binding,
  ComponentResult audio,
  ComponentResult metadata,
  TicketState state
});
typedef DeleteTarget = ({
  String id,
  BoundRecording? binding,
  String title,
  Eligibility eligibility,
  String? retryTicketId
});
typedef DeletionPreview = ({List<DeleteTarget> targets});
typedef ConfirmedDeletion = ({String operationId, List<DeleteTarget> targets});
typedef ConfirmedDeletionRetry = ({String operationId, List<String> ticketIds});

enum DeleteState { deleted, failed, skipped }

typedef DeletionItemResult = ({
  String id,
  DeleteState state,
  ComponentResult audio,
  ComponentResult metadata,
  String? ticketId,
  StorageProblem? problem
});
typedef BulkDeletionResult = ({List<DeletionItemResult> items, bool replayed});

enum ImportState {
  adopted,
  alreadyKnown,
  collision,
  retired,
  invalid,
  unavailable
}

typedef ImportedEntry = ({
  String id,
  StorageLocation source,
  AudioLocator audio,
  int sizeBytes,
  DateTime modifiedAt,
  Map<String, dynamic>? metadata,
  StorageProblem? problem
});
typedef ImportPreview = ({List<ImportedEntry> entries});
typedef ConfirmedImport = ({String operationId, List<ImportedEntry> entries});
typedef ImportItemResult = ({
  String id,
  ImportState state,
  StorageProblem? problem
});
typedef ImportResult = ({List<ImportItemResult> items});
typedef OwnedCaptureRecoveryResult = ({
  List<String> recoveredIds,
  List<String> retainedReservationIds,
  List<StorageProblem> problems
});
typedef PresentedDumpResults = ({
  String scopeKey,
  int generation,
  bool settled,
  List<DumpRow> rows,
  int? limit
});
typedef DumpSelectionState = ({
  bool active,
  Set<String> selectedIds,
  String scopeKey,
  int generation
});

typedef RestoredUse = ({RecordingKey key, UseKind kind, Future<void> settled});

abstract interface class IoOperation<T> {
  String get id;
  Future<T> get result;
  Future<void> get settled;
}

abstract interface class UseLease {
  RecordingKey get key;
  BoundRecording? get binding;
  Future<void> close();
}

abstract interface class AudioReadLease {
  RecordingKey get key;
  Future<Uint8List> read();
  Future<void> close();
}

abstract interface class PlaybackLease {
  RecordingKey get key;
  AudioLocator get source;
  RecordingPlaybackEngine get engine;
  Future<void> close();
}

abstract interface class MetadataPublicationAccess {
  BoundRecording get binding;
  Future<void> write(Map<String, dynamic> metadata);
}

abstract interface class StorageBackend {
  Future<List<RestoredUse>> unsettledUses();
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({
    required String filesystemLegacyDirectory,
    String? frozenAnchorJson,
  });
  Future<Outcome<StorageLocation?>> pickDirectory();
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(
    String token,
    StorageLocation location,
  );
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location);
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding);
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding);
  IoOperation<Outcome<PublishedCapture>> publishCapture(
    CaptureReservation reservation,
    Map<String, dynamic> metadata,
  );
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  );
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording binding,
    RecordingComponent component,
    String operationId,
  );
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
    StorageLocation location,
  );
  Future<void> drain();
}

abstract interface class RecordingMutationCoordinator {
  String get processEpoch;
  bool get hasActiveCapture;
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []});
  Future<Outcome<UseLease>> acquire(
    String dumpId,
    UseKind kind, {
    String? expectedIncarnation,
    String? retryTicketId,
  });
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start);
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation);
  Future<T> catalogAdmission<T>(Future<T> Function() operation);
  Stream<Map<String, Eligibility>> watchEligibility();
  Future<void> drain();
}

abstract interface class StorageCatalog {
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({
    required String filesystemLegacyDirectory,
  });
  Stream<DefaultFolderState> watchDefault();
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate();
  Future<Outcome<DefaultFolderState>> commitDefault(
    FolderCandidate candidate, {
    required int expectedRevision,
  });
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId);
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode});
}

abstract interface class RecordingAccess {
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key);
  Future<Outcome<PlaybackLease>> openPlayback(
    RecordingKey key,
    RecordingPlaybackEngine engine,
  );
  Future<T> runSerializedMetadataWrite<T>(
    RecordingKey key,
    Future<T> Function(MetadataPublicationAccess access) operation,
  );
}

abstract interface class RecordingCoordinator {
  Stream<RecordingLifecycleState> watchState();
  Future<Outcome<CaptureReservation>> start({required String mode});
  Future<Outcome<DumpRow?>> stopAndPersist();
}

abstract interface class LocalDeletionService {
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds);
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(
    ConfirmedDeletion request,
  );
  Future<Outcome<BulkDeletionResult>> retryConfirmed(
    ConfirmedDeletionRetry request,
  );
  Stream<Map<String, Eligibility>> watchEligibility();
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
  Future<Outcome<DeletionTicket>> claimLocalDeletion(
    String operationId,
    DeleteTarget target,
  );
  Future<void> recordDeletionComponent(
    String ticketId,
    RecordingComponent component,
    ComponentResult result,
  );
  Future<void> finishLocalDeletion(String ticketId);
  Future<List<DeletionTicket>> pendingLocalDeletions();
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100});
}
