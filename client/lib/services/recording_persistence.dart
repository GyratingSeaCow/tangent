// SPDX-License-Identifier: AGPL-3.0-or-later
import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import 'recording_service.dart';

class RecordingPersistence {
  final LocalTokenDb _db;
  final AudioStorage _storage;

  RecordingPersistence({required LocalDb db, required AudioStorage storage})
      : _db = LocalTokenDb(db),
        _storage = storage;

  Future<DumpRow> save(RecordingResult result, {required String mode}) async {
    final now = DateTime.now().toUtc();
    final filename = result.path.split(RegExp(r'[\\/]')).last;
    final id = filename.endsWith('.opus')
        ? filename.substring(0, filename.length - '.opus'.length)
        : filename;
    if (id.isEmpty) throw StateError('Recording filename has no identifier');

    final staged = DumpRow(
      id: id,
      createdAt: now,
      updatedAt: now,
      mode: mode,
      durationSeconds: result.durationSeconds,
      title: generatedRecordingTitle(now),
      audioPath: result.path,
      audioSizeBytes: result.sizeBytes,
      syncStatus: 'pending',
      syncAttempts: 0,
    );
    final stored = await _storage.persistRecording(
      id: id,
      temporaryPath: result.path,
      metadata: dumpMetadata(staged),
    );
    final durable = staged.copyWith(
      audioPath: stored.locator,
      audioSizeBytes: stored.sizeBytes,
    );
    await _db.upsert(durable);
    return durable;
  }
}

/// Keeps the persistence class narrow while retaining the concrete Drift DB API.
class LocalTokenDb {
  final LocalDb _db;
  const LocalTokenDb(this._db);
  Future<void> upsert(DumpRow row) => _db.upsertDump(row);
}
