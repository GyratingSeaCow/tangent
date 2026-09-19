// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import '../local_db.dart';
import '../../services/audio_gain.dart';
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

/// Primary-content file extension for a capture mode. Text notes publish
/// markdown; every audio mode publishes opus.
String contentExtensionForMode(String mode) =>
    mode == 'text_note' ? 'md' : 'opus';

/// Extension for a capture whose staging path is already known.
///
/// Prefer this over [contentExtensionForMode] anywhere a reservation exists.
/// The mode alone stopped being sufficient when microphone gain arrived: an
/// amplified capture is PCM in a WAV container, so mode-derived names expect
/// `<id>.opus` while the recorder legitimately wrote `<id>.wav`.
///
/// Verified on hardware: with the mode-only helper, staging validation
/// rejected every amplified recording, the record button appeared to do
/// nothing, and the recorder was left wedged for subsequent recordings until
/// the app was restarted.
String contentExtensionForReservation(String mode, String stagingPath) {
  if (mode == 'text_note') return 'md';
  for (final String candidate in <String>['opus', 'wav']) {
    if (stagingPath.endsWith('.$candidate')) return candidate;
  }
  // An unrecognised staging name is a programming error upstream; fall back to
  // the mode so behaviour matches the pre-gain build rather than inventing an
  // extension nothing can publish.
  return contentExtensionForMode(mode);
}

/// Extension a capture should be staged and published under.
///
/// Extends [contentExtensionForMode] with the microphone gain, because an
/// amplified capture is raw PCM in a WAV container rather than Opus --
/// package:record only exposes samples on its stream API. The mode alone is no
/// longer enough to name the file, so anything deriving a capture filename
/// must use this instead.
///
/// The Kotlin SAF port mirrors the resulting suffix set; see
/// [publishableContentSuffixes].
String stagingExtension({required String mode, required double gain}) =>
    captureExtensionForGain(mode, gain);

/// Every content suffix the app can publish.
///
/// Mirrored verbatim in Kotlin (`AndroidDocumentsPort`, `CapturePublication`).
/// A suffix missing on either side is a recording that cannot be published:
/// the SAF port rejects the staging path and the save leaves no row behind.
const List<String> publishableContentSuffixes = <String>['.opus', '.wav', '.md'];

/// Child directory of the user-chosen storage folder that owns published
/// text notes (`<id>.md` + `<id>.meta.json`). Audio modes keep publishing at
/// the folder root. The Kotlin SAF port mirrors this exact literal
/// (CaptureWire.TEXT_NOTE_DIRECTORY).
const String textNoteSubdirectoryName = 'Tangent Text Notes';

/// Child directory of the user-chosen storage folder that owns published
/// notebooks, a sibling of [textNoteSubdirectoryName]. The Kotlin SAF port
/// mirrors this exact literal (DocumentWire.NOTEBOOK_DIRECTORY).
const String notebookSubdirectoryName = 'Tangent Notebooks';

/// Child directory of the user-chosen storage folder that owns audio
/// downloaded from the sync server, a sibling of [notebookSubdirectoryName].
/// The Kotlin SAF port mirrors this exact literal
/// (DocumentWire.SYNCED_AUDIO_DIRECTORY).
///
/// Downloaded audio is kept out of the folder ROOT deliberately: the root
/// holds what this device captured, and a synced copy of a recording made on
/// another device is a different thing. Keeping them apart means a user
/// browsing the folder can tell which recordings are theirs from this device
/// without opening the app.
const String syncedAudioSubdirectoryName = 'Tangent Synced Audio';

/// Durable notebook filename suffix: one self-contained JSON document per
/// notebook, `<id>.notebook.json`, with no sidecar.
const String notebookFileSuffix = '.notebook.json';

/// One published, sidecar-free durable document inside a named child of the
/// owned tree. [locator] is the opaque, provider-issued identity of the exact
/// published document; it is NEVER parsed as a path.
typedef DurableDocument = ({
  String name,
  AudioLocator locator,
  String content
});

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

// Capture preparation v1; semantic sidecar and database schemas are unchanged.
typedef CaptureObjectIdentity = ({
  String kind,
  String scope,
  String objectId,
  String? generation
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
  // Transitional Phase A: the legacy publisher below remains unchanged until
  // Phase B migrates the sole persistence owner and removes it atomically.
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation reservation,
    String metadataJson,
    String audioSha256,
    String operationId, {
    required bool observeOnly,
  });
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(
    CaptureReservation reservation,
    PreparedCapture preparation,
  );
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation reservation,
    PreparedCapture preparation,
  );
  Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);

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

  /// Reads the single published entry for [dumpId], or null when it is absent.
  ///
  /// Publication proves its receipt by re-reading the entry it just wrote.
  /// Doing that via [listRecordingsAt] enumerated and parsed every recording
  /// in the folder — 4.4 seconds of a 5.9-second stop with 56 recordings (T8),
  /// the same defect as the record-start path (31645e8).
  ///
  /// Returns null when the backend cannot answer for one entry, so callers
  /// fall back to the full listing and no implementation is forced to change.
  IoOperation<Outcome<ImportedEntry?>>? readRecordingAt(
    StorageLocation location,
    String dumpId,
  ) =>
      null;

  /// Publishes one sidecar-free durable document called [name] into the
  /// [directoryName] child of [location], creating that child idempotently.
  /// Replaces an existing same-name document atomically. A same-name
  /// non-directory blocking the child is a conflict, never a root fallback.
  IoOperation<Outcome<DurableDocument>> publishDocument(
    StorageLocation location,
    String directoryName,
    String name,
    String content,
    String publicationId,
  );

  /// Publishes one sidecar-free durable document called [name] carrying raw
  /// [bytes] into the [directoryName] child of [location].
  ///
  /// The text [publishDocument] above cannot carry audio: the Kotlin side
  /// encodes its content as UTF-8 and verifies readback against those bytes,
  /// which corrupts anything that is not text. Downloaded audio needs a real
  /// binary write, and it must be a playable file in the user's folder rather
  /// than an encoded blob.
  ///
  /// Returns `Unsupported` by default so a backend that cannot write binary
  /// documents keeps compiling and simply never offers audio download; only
  /// the backends that genuinely support it override this.
  IoOperation<Outcome<DurableDocument>> publishBinaryDocument(
    StorageLocation location,
    String directoryName,
    String name,
    List<int> bytes,
    String mimeType,
    String publicationId,
  );

  /// Enumerates durable documents whose name ends with [suffix] inside the
  /// [directoryName] child. An absent child enumerates as empty.
  IoOperation<Outcome<List<DurableDocument>>> listDocuments(
    StorageLocation location,
    String directoryName,
    String suffix,
  );

  /// Deletes the exact document identified by [locator] (opaque, never parsed
  /// as a path) from the [directoryName] child, verified by [name].
  IoOperation<ComponentResult> deleteDocument(
    StorageLocation location,
    String directoryName,
    String name,
    AudioLocator locator,
    String operationId,
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
  Future<Outcome<CaptureReservation>> reserveCapture({
    required String mode,
    double gain,
  });
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
