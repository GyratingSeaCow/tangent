// SPDX-License-Identifier: AGPL-3.0-or-later
import '../models/transcription_status.dart';
import 'local_db.dart';
import 'storage/storage_contract.dart';

/// Validate external sidecars before the legacy-compatible serializer runs.
/// Absent optional/nullable fields retain their existing restoration semantics.
void validateImportedMetadata(String id, Map<String, dynamic>? metadata) {
  if (metadata == null) return;
  Never invalid() => throw const StorageFault(
        (code: ProblemCode.invalid, message: 'Invalid recording sidecar'),
      );
  if (metadata['id'] != id ||
      metadata['schemaVersion'] is! int ||
      !const [1, 2].contains(metadata['schemaVersion'])) {
    invalid();
  }
  for (final key in [
    'title',
    'mode',
    'transcript',
    'meetingNotes',
    'syncStatus',
    'lastSyncError',
    'transcriptionStatus',
    'transcriptionRequestId',
    'transcriptionJobId',
    'transcriptionError',
  ]) {
    if (metadata[key] != null && metadata[key] is! String) invalid();
  }
  for (final key in [
    'durationSeconds',
    'audioSizeBytes',
    'syncAttempts',
    'transcriptionAttempt',
  ]) {
    final value = metadata[key];
    if (value != null && (value is! int || value < 0)) invalid();
  }
  for (final key in [
    'createdAt',
    'updatedAt',
    'transcriptionStartedAt',
    'transcriptionUpdatedAt',
    'transcriptionCompletedAt',
  ]) {
    final value = metadata[key];
    if (value != null &&
        (value is! String || DateTime.tryParse(value) == null)) {
      invalid();
    }
  }
  if (metadata['mode'] != null &&
      !const ['brain_dump', 'meeting', 'text_note']
          .contains(metadata['mode'])) {
    invalid();
  }
  if (metadata['transcriptionStatus'] != null &&
      !TranscriptionStatus.values
          .any((s) => s.wireValue == metadata['transcriptionStatus'])) {
    invalid();
  }
}

const recordingMetadataSchemaVersion = 2;

String generatedRecordingTitle(DateTime createdAt) {
  final local = createdAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Recording ${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}-${two(local.minute)}-${two(local.second)}';
}

String generatedNoteTitle(DateTime createdAt) {
  final local = createdAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Note ${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}-${two(local.minute)}-${two(local.second)}';
}

Map<String, dynamic> dumpMetadata(DumpRow row) => {
      'schemaVersion': recordingMetadataSchemaVersion,
      'id': row.id,
      'createdAt': row.createdAt.toUtc().toIso8601String(),
      'updatedAt': row.updatedAt.toUtc().toIso8601String(),
      'mode': row.mode,
      'durationSeconds': row.durationSeconds,
      'title': row.title,
      'transcript': row.transcript,
      'meetingNotes': row.meetingNotes,
      'transcriptionStatus': row.transcriptionStatus,
      'transcriptionRequestId': row.transcriptionRequestId,
      'transcriptionJobId': row.transcriptionJobId,
      'transcriptionAttempt': row.transcriptionAttempt,
      'transcriptionStartedAt':
          row.transcriptionStartedAt?.toUtc().toIso8601String(),
      'transcriptionUpdatedAt':
          row.transcriptionUpdatedAt?.toUtc().toIso8601String(),
      'transcriptionCompletedAt':
          row.transcriptionCompletedAt?.toUtc().toIso8601String(),
      'transcriptionError': row.transcriptionError,
      'audioSizeBytes': row.audioSizeBytes,
      'syncStatus': row.syncStatus,
      'syncAttempts': row.syncAttempts,
      'lastSyncError': row.lastSyncError,
    };

DumpRow importedDumpRow({
  required String id,
  required String locator,
  required int sizeBytes,
  required DateTime modifiedAt,
  Map<String, dynamic>? metadata,
}) {
  DateTime date(String key, DateTime fallback) {
    final raw = metadata?[key];
    return raw is String
        ? DateTime.tryParse(raw)?.toUtc() ?? fallback
        : fallback;
  }

  int number(String key, int fallback) {
    final raw = metadata?[key];
    return raw is num ? raw.toInt() : fallback;
  }

  String text(String key, String fallback) {
    final raw = metadata?[key];
    return raw is String ? raw : fallback;
  }

  String? nullableText(String key) {
    final raw = metadata?[key];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  DateTime? utcDate(String key) {
    final raw = nullableText(key);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  final modifiedUtc = modifiedAt.toUtc();
  final createdAt = date('createdAt', modifiedUtc);
  final restoredTitle = text('title', '').trim();
  final transcript = metadata?['transcript'] as String?;
  final schemaVersion = number('schemaVersion', 1);
  final mode = text('mode', 'brain_dump');
  // A restored note is never transcribable: absent/degraded sidecar status
  // must fall back to the terminal note status, and an untitled note gets a
  // Note title, not a Recording title.
  final isNote = mode == 'text_note';
  final legacyStatus = isNote
      ? 'not_applicable'
      : transcript != null && transcript.trim().isNotEmpty
          ? 'completed'
          : 'not_transcribed';
  final importedStatus = nullableText('transcriptionStatus');
  final validImportedStatus = TranscriptionStatus.values.any(
    (status) => status.wireValue == importedStatus,
  );
  return DumpRow(
    id: id,
    createdAt: createdAt,
    updatedAt: date('updatedAt', modifiedUtc),
    mode: mode,
    durationSeconds: number('durationSeconds', 0),
    title: restoredTitle.isEmpty
        ? isNote
            ? generatedNoteTitle(createdAt)
            : generatedRecordingTitle(createdAt)
        : restoredTitle,
    transcript: transcript,
    meetingNotes: metadata?['meetingNotes'] as String?,
    audioPath: locator,
    audioSizeBytes: sizeBytes,
    syncStatus: text('syncStatus', 'pending'),
    syncAttempts: number('syncAttempts', 0),
    lastSyncError: metadata?['lastSyncError'] as String?,
    transcriptionStatus: schemaVersion >= 2
        ? validImportedStatus
            ? importedStatus!
            : legacyStatus
        : legacyStatus,
    transcriptionRequestId:
        schemaVersion >= 2 ? nullableText('transcriptionRequestId') : null,
    transcriptionJobId:
        schemaVersion >= 2 ? nullableText('transcriptionJobId') : null,
    transcriptionAttempt:
        schemaVersion >= 2 ? number('transcriptionAttempt', 0) : 0,
    transcriptionStartedAt:
        schemaVersion >= 2 ? utcDate('transcriptionStartedAt') : null,
    transcriptionUpdatedAt:
        schemaVersion >= 2 ? utcDate('transcriptionUpdatedAt') : null,
    transcriptionCompletedAt:
        schemaVersion >= 2 ? utcDate('transcriptionCompletedAt') : null,
    transcriptionError:
        schemaVersion >= 2 ? nullableText('transcriptionError') : null,
  );
}
