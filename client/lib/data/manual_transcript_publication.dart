// SPDX-License-Identifier: AGPL-3.0-or-later
import 'audio_storage.dart';
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
  required AudioStorage audio,
  required DumpRow revision,
  DateTime Function()? now,
  void Function()? checkActive,
  Future<void> Function(String, Map<String, dynamic>)? metadataWriter,
}) {
  final marker = revision.transcriptionError;
  if (!(marker?.startsWith('sidecar_sync_pending: manual_edit:') ?? false)) {
    throw ArgumentError('A committed manual edit marker is required');
  }
  return audio.runSerializedMetadataWrite<bool>(revision.id, (write) async {
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
      await write(metadata);
    } else {
      await metadataWriter(current.id, metadata);
    }
    checkActive?.call();
    final acknowledged = await db.updateTranscriptionSidecarError(
      current.id,
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
