// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/sync_status.dart';
import '../models/transcription_status.dart';
import 'storage/storage_tables.dart';

part 'local_db.g.dart';

@DataClassName('DumpRow')
class Dumps extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get mode => text().withLength(min: 1, max: 20)();
  IntColumn get durationSeconds => integer()();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get transcript => text().nullable()();
  TextColumn get meetingNotes => text().nullable()();
  TextColumn get audioPath => text()();
  IntColumn get audioSizeBytes => integer()();
  TextColumn get syncStatus => text().withLength(min: 1, max: 20)();
  IntColumn get syncAttempts => integer().withDefault(const Constant(0))();
  TextColumn get lastSyncError => text().nullable()();
  TextColumn get transcriptionStatus => text().withDefault(
        Constant(TranscriptionStatus.notTranscribed.wireValue),
      )();
  TextColumn get transcriptionRequestId => text().nullable()();
  TextColumn get transcriptionJobId => text().nullable()();
  IntColumn get transcriptionAttempt =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get transcriptionStartedAt => dateTime().nullable()();
  DateTimeColumn get transcriptionUpdatedAt => dateTime().nullable()();
  DateTimeColumn get transcriptionCompletedAt => dateTime().nullable()();
  TextColumn get transcriptionError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SyncQueueRow')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dumpId =>
      text().references(Dumps, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get queuedAt => dateTime()();
}

@DriftDatabase(
  tables: [
    Dumps,
    SyncQueue,
    StorageLocations,
    StorageCatalogStates,
    RecordingBindings,
    CaptureReservations,
    LocalDeletionBatches,
    LocalDeletionTickets,
  ],
)
class LocalDb extends _$LocalDb {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsInfrastructure();
          await initializeStorageCatalogRows();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await _replaceFtsTriggers();
          }
          if (from < 3) {
            await m.addColumn(dumps, dumps.meetingNotes);
            // Migration v2 → v3 promotes meetings to private on-device state.
            // Already-synced meetings remain synced because the remote copy is
            // truth and we cannot prove the server has deleted it. Pending,
            // syncing, and failed meetings are demoted to local_only and have
            // their stale retry state cleared so the user does not see error
            // strings on rows that will never retry.
            await customStatement(
              'UPDATE dumps SET sync_status = \'local_only\', '
              'sync_attempts = 0, last_sync_error = NULL '
              'WHERE mode = \'meeting\' AND sync_status IN (\'pending\', \'syncing\', \'failed\')',
            );
          }
          if (from < 4) {
            await m.addColumn(dumps, dumps.transcriptionStatus);
            await m.addColumn(dumps, dumps.transcriptionRequestId);
            await m.addColumn(dumps, dumps.transcriptionJobId);
            await m.addColumn(dumps, dumps.transcriptionAttempt);
            await m.addColumn(dumps, dumps.transcriptionStartedAt);
            await m.addColumn(dumps, dumps.transcriptionUpdatedAt);
            await m.addColumn(dumps, dumps.transcriptionCompletedAt);
            await m.addColumn(dumps, dumps.transcriptionError);
            await customStatement(
              'UPDATE dumps SET transcription_status = CASE '
              "WHEN TRIM(COALESCE(transcript, '')) != '' THEN 'completed' "
              "ELSE 'not_transcribed' END, "
              'transcription_completed_at = CASE '
              "WHEN TRIM(COALESCE(transcript, '')) != '' THEN updated_at "
              'ELSE NULL END',
            );
          }
          if (from < 5) {
            await _createStorageCatalog(m);
          }
        },
      );

  Future<void> _createStorageCatalog(Migrator m) async {
    await m.createTable(storageLocations);
    await m.createTable(storageCatalogStates);
    await m.createTable(recordingBindings);
    await m.createTable(captureReservations);
    await m.createTable(localDeletionBatches);
    await m.createTable(localDeletionTickets);
    await initializeStorageCatalogRows();
  }

  Future<void> initializeStorageCatalogRows() async {
    await customStatement(
      'INSERT OR IGNORE INTO storage_catalog_state(id) VALUES(1)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS capture_state_idx ON capture_reservations(state)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS deletion_state_idx ON local_deletion_tickets(state)',
    );
  }

  Future<void> _createFtsInfrastructure() async {
    await customStatement(
      '''CREATE VIRTUAL TABLE IF NOT EXISTS dumps_fts USING fts5(
        title, transcript, content="dumps", content_rowid="rowid"
      )''',
    );
    await _createFtsTriggers();
  }

  Future<void> _replaceFtsTriggers() async {
    await customStatement('DROP TRIGGER IF EXISTS dumps_ai');
    await customStatement('DROP TRIGGER IF EXISTS dumps_ad');
    await customStatement('DROP TRIGGER IF EXISTS dumps_au');
    await _createFtsTriggers();
  }

  Future<void> _createFtsTriggers() async {
    await customStatement(
      '''CREATE TRIGGER dumps_ai AFTER INSERT ON dumps BEGIN
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''',
    );
    await customStatement(
      '''CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
      END''',
    );
    await customStatement(
      '''CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''',
    );
  }

  /// Insert or replace a dump row.
  Future<void> upsertDump(DumpRow row) =>
      into(dumps).insertOnConflictUpdate(row);

  /// Delete a dump row by id.
  Future<int> deleteDump(String id) =>
      (delete(dumps)..where((d) => d.id.equals(id))).go();

  /// Fetch dumps, newest first, with pagination.
  Future<List<DumpRow>> listDumps({int limit = 50, int offset = 0}) {
    return (select(dumps)
          ..orderBy([(d) => OrderingTerm.desc(d.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Reactive stream of all dumps, newest first.
  /// Emits whenever any row in [dumps] changes.
  Stream<List<DumpRow>> watchAllDumps() {
    return (select(dumps)..orderBy([(d) => OrderingTerm.desc(d.createdAt)]))
        .watch();
  }

  /// Reactive stream for one dump without retaining or rescanning the table.
  Stream<DumpRow?> watchDump(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).watchSingleOrNull();

  /// Search across title and transcript using FTS5.
  Future<List<DumpRow>> searchDumps(String query, {int limit = 50}) {
    final escaped = query.replaceAll('"', '""');
    return customSelect(
      'SELECT d.* FROM dumps d '
      'JOIN dumps_fts f ON d.rowid = f.rowid '
      'WHERE dumps_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [
        Variable.withString('"$escaped"'),
        Variable.withInt(limit),
      ],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).get();
  }

  /// Find a dump by id.
  Future<DumpRow?> getDump(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).getSingleOrNull();

  /// Updates only the editable title columns, preserving transcription state.
  Future<DumpRow> updateDumpTitle(
    String id, {
    required String title,
    required DateTime now,
  }) {
    return transaction(() async {
      final count = await (update(dumps)..where((d) => d.id.equals(id))).write(
        DumpsCompanion(
          title: Value(title),
          updatedAt: Value(now.toUtc()),
        ),
      );
      if (count != 1) throw StateError('Dump not found: $id');
      return (await getDump(id))!;
    });
  }

  /// Updates meeting notes only when they were derived from the current
  /// title and durable transcript revision, preserving every transcription
  /// ownership column.
  Future<DumpRow> updateDumpMeetingNotes(
    String id, {
    required String expectedTitle,
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String meetingNotes,
    required DateTime now,
  }) {
    return transaction(() async {
      final count = await (update(dumps)
            ..where(
              (d) {
                final requestIdMatches = expectedTranscriptionRequestId == null
                    ? d.transcriptionRequestId.isNull()
                    : d.transcriptionRequestId.equals(
                        expectedTranscriptionRequestId,
                      );
                return d.id.equals(id) &
                    d.title.equals(expectedTitle) &
                    d.transcript.equals(expectedTranscript) &
                    d.transcriptionAttempt.equals(
                      expectedTranscriptionAttempt,
                    ) &
                    requestIdMatches;
              },
            ))
          .write(
        DumpsCompanion(
          meetingNotes: Value(meetingNotes),
          updatedAt: Value(now.toUtc()),
        ),
      );
      if (count != 1) {
        throw StateError(
          'Dump title or transcript revision changed while editing notes: $id',
        );
      }
      return (await getDump(id))!;
    });
  }

  /// Saves a manual transcript edit only against the exact completed
  /// transcription revision the editor opened. A newer attempt or result wins.
  Future<DumpRow> updateDumpTranscript(
    String id, {
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String transcript,
    required DateTime now,
  }) {
    if (transcript.trim().isEmpty) {
      throw ArgumentError.value(transcript, 'transcript', 'must not be blank');
    }
    return transaction(() async {
      final current = await getDump(id);
      final priorError = errorAfterSidecarSync(current?.transcriptionError);
      final count = await (update(dumps)
            ..where(
              (d) {
                final requestIdMatches = expectedTranscriptionRequestId == null
                    ? d.transcriptionRequestId.isNull()
                    : d.transcriptionRequestId.equals(
                        expectedTranscriptionRequestId,
                      );
                return d.id.equals(id) &
                    d.transcriptionStatus.isIn([
                      TranscriptionStatus.completed.wireValue,
                      TranscriptionStatus.failed.wireValue,
                    ]) &
                    d.transcript.equals(expectedTranscript) &
                    d.transcriptionAttempt.equals(
                      expectedTranscriptionAttempt,
                    ) &
                    requestIdMatches;
              },
            ))
          .write(
        DumpsCompanion(
          transcript: Value(transcript),
          transcriptionError:
              Value('sidecar_sync_pending: manual_edit:${jsonEncode({
                'error': priorError,
                'revision': const Uuid().v4(),
              })}'),
          updatedAt: Value(now.toUtc()),
        ),
      );
      if (count != 1) {
        throw StateError(
          'Transcript revision changed while editing: $id',
        );
      }
      return (await getDump(id))!;
    });
  }

  /// Manual-edit markers retain a failed attempt's original diagnostic.
  static String? errorAfterSidecarSync(String? error) {
    const prefix = 'sidecar_sync_pending: manual_edit:';
    if (error?.startsWith(prefix) ?? false) {
      final payload = jsonDecode(error!.substring(prefix.length));
      return payload is Map ? payload['error'] as String? : payload as String?;
    }
    return (error?.startsWith('sidecar_sync_pending:') ?? false) ? null : error;
  }

  /// Starts a new durable transcription attempt before any network I/O.
  Future<DumpRow> beginTranscriptionAttempt(
    String id, {
    required String requestId,
    required DateTime now,
  }) {
    return transaction(() async {
      final current = await getDump(id);
      if (current == null) throw StateError('Dump not found: $id');
      final currentStatus =
          TranscriptionStatus.fromWire(current.transcriptionStatus);
      final sidecarPending = currentStatus.isTerminal &&
          (current.transcriptionError?.startsWith('sidecar_sync_pending:') ??
              false);
      if (currentStatus.isInProgress || sidecarPending) {
        throw StateError('Transcription already in progress: $id');
      }
      final timestamp = now.toUtc();
      final nextAttempt = current.transcriptionAttempt + 1;
      await (update(dumps)..where((d) => d.id.equals(id))).write(
        DumpsCompanion(
          updatedAt: Value(timestamp),
          transcriptionStatus: Value(TranscriptionStatus.uploading.wireValue),
          transcriptionRequestId: Value(requestId),
          transcriptionJobId: const Value(null),
          transcriptionAttempt: Value(nextAttempt),
          transcriptionStartedAt: Value(timestamp),
          transcriptionUpdatedAt: Value(timestamp),
          transcriptionCompletedAt: const Value(null),
          transcriptionError: const Value(null),
        ),
      );
      return (await getDump(id))!;
    });
  }

  /// Updates an attempt only if it is still the latest attempt for the dump.
  Future<bool> updateTranscriptionStatus(
    String id, {
    required int attempt,
    required String requestId,
    required TranscriptionStatus status,
    required DateTime now,
    String? jobId,
    String? error,
  }) async {
    final timestamp = now.toUtc();
    final allowedSourceStatuses = switch (status) {
      TranscriptionStatus.notTranscribed => const <String>['__never__'],
      TranscriptionStatus.uploading => <String>[
          TranscriptionStatus.uploading.wireValue,
        ],
      TranscriptionStatus.queued => <String>[
          TranscriptionStatus.uploading.wireValue,
          TranscriptionStatus.queued.wireValue,
        ],
      TranscriptionStatus.running => <String>[
          TranscriptionStatus.uploading.wireValue,
          TranscriptionStatus.queued.wireValue,
          TranscriptionStatus.running.wireValue,
        ],
      TranscriptionStatus.completed || TranscriptionStatus.failed => <String>[
          TranscriptionStatus.uploading.wireValue,
          TranscriptionStatus.queued.wireValue,
          TranscriptionStatus.running.wireValue,
        ],
    };
    final count = await (update(dumps)
          ..where(
            (d) =>
                d.id.equals(id) &
                d.transcriptionAttempt.equals(attempt) &
                d.transcriptionRequestId.equals(requestId) &
                d.transcriptionStatus.isIn(allowedSourceStatuses),
          ))
        .write(
      DumpsCompanion(
        updatedAt: Value(timestamp),
        transcriptionStatus: Value(status.wireValue),
        transcriptionJobId: jobId == null ? const Value.absent() : Value(jobId),
        transcriptionUpdatedAt: Value(timestamp),
        transcriptionCompletedAt:
            status.isTerminal ? Value(timestamp) : const Value.absent(),
        transcriptionError: Value(error),
      ),
    );
    return count == 1;
  }

  /// Commits transcript output only for the current attempt.
  Future<bool> completeTranscriptionAttempt(
    String id, {
    required int attempt,
    required String requestId,
    required String transcript,
    String? meetingNotes,
    required DateTime now,
    String? sidecarError,
  }) =>
      transaction(() async {
        // Read and mutate under the same SQLite transaction. A replacement must
        // never write a snapshot of notes over an explicit regeneration.
        final current = await getDump(id);
        final preserveNotes = current?.transcript?.trim().isNotEmpty ?? false;
        final timestamp = now.toUtc();
        final count = await (update(dumps)
              ..where(
                (d) =>
                    d.id.equals(id) &
                    d.transcriptionAttempt.equals(attempt) &
                    d.transcriptionRequestId.equals(requestId) &
                    (d.transcriptionStatus.equals(
                          TranscriptionStatus.uploading.wireValue,
                        ) |
                        d.transcriptionStatus.equals(
                          TranscriptionStatus.queued.wireValue,
                        ) |
                        d.transcriptionStatus.equals(
                          TranscriptionStatus.running.wireValue,
                        )),
              ))
            .write(
          DumpsCompanion(
            updatedAt: Value(timestamp),
            transcript: Value(transcript),
            meetingNotes:
                preserveNotes ? const Value.absent() : Value(meetingNotes),
            transcriptionStatus: Value(TranscriptionStatus.completed.wireValue),
            transcriptionUpdatedAt: Value(timestamp),
            transcriptionCompletedAt: Value(timestamp),
            transcriptionError: Value(sidecarError),
          ),
        );
        return count == 1;
      });

  /// Updates the sidecar repair marker only for the winning completed attempt.
  Future<bool> updateTranscriptionSidecarError(
    String id, {
    required int attempt,
    required String? requestId,
    required String? error,
    required DateTime now,
    String? expectedTranscript,
    String? expectedError,
  }) async {
    final timestamp = now.toUtc();
    final count = await (update(dumps)
          ..where(
            (d) =>
                d.id.equals(id) &
                d.transcriptionAttempt.equals(attempt) &
                (requestId == null
                    ? d.transcriptionRequestId.isNull()
                    : d.transcriptionRequestId.equals(requestId)) &
                d.transcriptionStatus.isIn(['completed', 'failed']) &
                (expectedTranscript == null
                    ? const Constant(true)
                    : d.transcript.equals(expectedTranscript)) &
                (expectedError == null
                    ? const Constant(true)
                    : d.transcriptionError.equals(expectedError)),
          ))
        .write(
      DumpsCompanion(
        updatedAt: Value(timestamp),
        transcriptionUpdatedAt: Value(timestamp),
        transcriptionError: Value(error),
      ),
    );
    return count == 1;
  }

  /// Rows whose latest attempt needs network or sidecar reconciliation.
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() =>
      _transcriptionRecoveryQuery().get();

  /// Observe commits even after their initiating route/coordinator disappears.
  Stream<List<DumpRow>> watchDumpsNeedingTranscriptionRecovery() =>
      _transcriptionRecoveryQuery().watch();

  Selectable<DumpRow> _transcriptionRecoveryQuery() {
    return (select(dumps)
      ..where(
        (d) =>
            d.transcriptionStatus.isIn([
              TranscriptionStatus.uploading.wireValue,
              TranscriptionStatus.queued.wireValue,
              TranscriptionStatus.running.wireValue,
            ]) |
            (d.transcriptionStatus.isIn(['completed', 'failed']) &
                d.transcriptionError.like('sidecar_sync_pending:%')),
      )
      ..orderBy([(d) => OrderingTerm.asc(d.transcriptionStartedAt)]));
  }

  /// Update only the sync fields for a dump.
  Future<void> updateSyncStatus(
    String id,
    SyncStatus status, {
    int? attempts,
    String? lastError,
  }) async {
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        syncStatus: Value(status.wireValue),
        syncAttempts: attempts != null ? Value(attempts) : const Value.absent(),
        lastSyncError:
            lastError != null ? Value(lastError) : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Find all dumps that need uploading. Excludes synced rows, local-only
  /// rows, and meeting recordings, which are intentionally kept private.
  Future<List<DumpRow>> dumpsNeedingUpload({int maxAttempts = 5}) {
    return customSelect(
      'SELECT * FROM dumps '
      "WHERE sync_status NOT IN ('synced', 'local_only') "
      "AND mode != 'meeting' "
      'AND sync_attempts < ? '
      'ORDER BY created_at ASC',
      variables: [
        Variable.withInt(maxAttempts),
      ],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).get();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tangent.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
