// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import '../data/local_db.dart';
import '../data/storage/storage_contract.dart';
import 'recording_persistence.dart';
import 'recording_service.dart';

/// Persists a typed text note through the owned-capture pipeline: the note
/// body is staged as UTF-8 `<id>.md`, published into the primary-content
/// slot beside its sidecar, and committed as a `text_note` dump row whose
/// transcript holds the note text (`transcriptionStatus='not_applicable'`,
/// `durationSeconds=0`, `audioSizeBytes` = the real `.md` byte length).
class NotePersistence {
  NotePersistence({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
    required StorageCatalog catalog,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations,
        _catalog = catalog;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  final StorageCatalog _catalog;

  T _value<T>(Outcome<T> value) => switch (value) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem),
      };

  Future<DumpRow> saveNote({
    required String text,
    required DateTime now,
  }) async {
    // Blank rejection precedes ANY reservation: no staging file, no
    // capture_reservations row, nothing for recovery to find.
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'Note text must not be blank');
    }
    final r = _value(await _catalog.reserveCapture(mode: 'text_note'));
    final bytes = utf8.encode(text);
    await File(r.stagingPath).writeAsBytes(bytes, flush: true);
    final lease = _value(
      await _mutations.acquire(
        r.key.dumpId,
        UseKind.capture,
        expectedIncarnation: r.key.incarnation,
      ),
    );
    try {
      return await _mutations.serialize(
        r.key,
        () => RecordingPersistence(
          db: _db,
          backend: _backend,
          mutations: _mutations,
        ).save(
          r,
          RecordingResult(
            path: r.stagingPath,
            durationSeconds: 0,
            sizeBytes: bytes.length,
          ),
          now: now,
          lease: lease,
        ),
      );
    } finally {
      await lease.close();
    }
  }
}
