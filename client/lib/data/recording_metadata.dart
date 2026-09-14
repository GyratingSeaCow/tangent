// SPDX-License-Identifier: AGPL-3.0-or-later
import 'local_db.dart';

const recordingMetadataSchemaVersion = 1;

String generatedRecordingTitle(DateTime createdAt) {
  final local = createdAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Recording ${local.year}-${two(local.month)}-${two(local.day)} '
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

  final modifiedUtc = modifiedAt.toUtc();
  final createdAt = date('createdAt', modifiedUtc);
  final restoredTitle = text('title', '').trim();
  return DumpRow(
    id: id,
    createdAt: createdAt,
    updatedAt: date('updatedAt', modifiedUtc),
    mode: text('mode', 'brain_dump'),
    durationSeconds: number('durationSeconds', 0),
    title: restoredTitle.isEmpty
        ? generatedRecordingTitle(createdAt)
        : restoredTitle,
    transcript: metadata?['transcript'] as String?,
    meetingNotes: metadata?['meetingNotes'] as String?,
    audioPath: locator,
    audioSizeBytes: sizeBytes,
    syncStatus: text('syncStatus', 'pending'),
    syncAttempts: number('syncAttempts', 0),
    lastSyncError: metadata?['lastSyncError'] as String?,
  );
}
