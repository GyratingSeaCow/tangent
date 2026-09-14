// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/sync_status.dart';

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

@DriftDatabase(tables: [Dumps, SyncQueue])
class LocalDb extends _$LocalDb {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsInfrastructure();
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
        },
      );

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
