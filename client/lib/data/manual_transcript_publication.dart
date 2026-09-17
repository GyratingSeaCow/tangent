// SPDX-License-Identifier: AGPL-3.0-or-later
import 'storage/storage_contract.dart';
import 'local_db.dart';
import 'recording_metadata.dart';

/// Publishes one committed manual edit, shared by its caller and recovery owner.
///
/// The exact marker is a one-use publication barrier. Under the serializer an
/// already acknowledged edit is a successful no-op; a newer revision is not
/// ours to write or acknowledge. Generic title/notes publication is separate.
/// Returns false if this revision has been superseded.
Future<bool> publishManualTranscriptSidecar({
  required LocalDb db,
  required RecordingAccess access,
  required RecordingKey storageKey,
  required DumpRow revision,
  DateTime Function()? now,
  void Function()? checkActive,
  Future<void> Function(BoundRecording, Map<String, dynamic>)? metadataWriter,
}) {
  if (revision.id != storageKey.dumpId) {
    throw const StorageFault(
      (
        code: ProblemCode.wrongIncarnation,
        message: 'Manual revision differs from captured recording key'
      ),
    );
  }
  final marker = revision.transcriptionError;
  if (!(marker?.startsWith('sidecar_sync_pending: manual_edit:') ?? false)) {
    throw ArgumentError('A committed manual edit marker is required');
  }
  return access.runSerializedMetadataWrite<bool>(storageKey, (writer) async {
    checkActive?.call();
    final current = await db.getDump(revision.id);
    checkActive?.call();
    if (current == null ||
        current.transcriptionAttempt != revision.transcriptionAttempt ||
        current.transcriptionRequestId != revision.transcriptionRequestId ||
        current.transcriptionStatus != revision.transcriptionStatus ||
        !['completed', 'failed'].contains(current.transcriptionStatus) ||
        current.transcript != revision.transcript) {
      return false;
    }
    final restoredError = LocalDb.errorAfterSidecarSync(marker);
    if (current.transcriptionError != marker) {
      // No file mutation is allowed after acknowledgement, or on behalf of a
      // different (including newer same-text) pending marker.
      return current.transcriptionError == restoredError;
    }
    final metadata = dumpMetadata(current)
      ..['transcriptionError'] = restoredError;
    if (metadataWriter == null) {
      await writer.write(metadata);
    } else {
      await metadataWriter(writer.binding, metadata);
    }
    checkActive?.call();
    final acknowledged = await db.updateTranscriptionSidecarError(
      current.id,
      storageKey: storageKey,
      attempt: revision.transcriptionAttempt,
      requestId: revision.transcriptionRequestId,
      expectedTranscript: revision.transcript,
      expectedError: marker,
      error: restoredError,
      now: (now ?? DateTime.now)().toUtc(),
    );
    checkActive?.call();
    return acknowledged;
  });
}
