// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import '../../support/storage_migration_fixture.dart';
import '../../support/resolved_temp.dart';

void verifyCatalogSchema(Database db) {
  const expected = {
    'storage_locations': [
      'id',
      'canonical_key',
      'directory_json',
      'label',
      'legacy_restore',
    ],
    'storage_catalog_state': [
      'id',
      'default_location_id',
      'revision',
      'bootstrap_version',
      'legacy_anchor_json',
      'candidate_json',
    ],
    'recording_bindings': [
      'dump_id',
      'incarnation',
      'location_id',
      'audio_json',
      'metadata_name',
      'legacy_anchor_json',
      'resolved',
    ],
    'capture_reservations': [
      'reservation_id',
      'dump_id',
      'incarnation',
      'location_id',
      'staging_path',
      'mode',
      'started_at',
      'state',
      'process_epoch',
      'publication_json',
    ],
    'local_deletion_batches': [
      'operation_id',
      'payload_json',
      'results_json',
      'state',
    ],
    'local_deletion_tickets': [
      'dump_id',
      'incarnation',
      'ticket_id',
      'operation_id',
      'binding_json',
      'audio_state',
      'metadata_state',
      'state',
      'problem_json',
    ],
  };
  for (final entry in expected.entries) {
    expect(
      db
          .select('PRAGMA table_info(${entry.key})')
          .map((r) => r['name'])
          .toList(),
      entry.value,
    );
    expect(
      db.select('PRAGMA foreign_key_list(${entry.key})'),
      isEmpty,
      reason: 'New receipts and bindings must not cascade with semantic rows',
    );
  }
  expect(
    db.select('PRAGMA index_info(capture_state_idx)').single['name'],
    'state',
  );
  expect(
    db.select('PRAGMA index_info(deletion_state_idx)').single['name'],
    'state',
  );
  expect(db.select('SELECT * FROM storage_catalog_state').single, {
    'id': 1,
    'default_location_id': null,
    'revision': 0,
    'bootstrap_version': 0,
    'legacy_anchor_json': null,
    'candidate_json': null,
  });
  expect(
    () => db.execute('INSERT INTO storage_catalog_state(id) VALUES(2)'),
    throwsA(isA<SqliteException>()),
  );
  db.execute(
    "INSERT INTO storage_locations(id,canonical_key,directory_json,label) VALUES('fixture-a','same','{}','A')",
  );
  expect(
    db
        .select('SELECT legacy_restore FROM storage_locations')
        .single['legacy_restore'],
    0,
  );
  expect(
    () => db.execute(
      "INSERT INTO storage_locations(id,canonical_key,directory_json,label) VALUES('fixture-b','same','{}','B')",
    ),
    throwsA(isA<SqliteException>()),
  );
  db.execute(
      """INSERT INTO capture_reservations(reservation_id,dump_id,incarnation,location_id,staging_path,mode,started_at,state,process_epoch)
VALUES('reservation-one','fixture-capture','inc','fixture-a','/synthetic/stage','meeting',1,'reserved','epoch')""");
  expect(
    () => db.execute(
        """INSERT INTO capture_reservations(reservation_id,dump_id,incarnation,location_id,staging_path,mode,started_at,state,process_epoch)
VALUES('reservation-two','fixture-capture','inc','fixture-a','/synthetic/stage','meeting',1,'reserved','epoch')"""),
    throwsA(isA<SqliteException>()),
  );
  db.execute(
      """INSERT INTO local_deletion_tickets(dump_id,incarnation,ticket_id,operation_id,binding_json,audio_state,metadata_state,state)
VALUES('fixture-retired','inc','ticket-one','operation-one','{}','removed','absent','completed')""");
  expect(
    () => db.execute(
        """INSERT INTO local_deletion_tickets(dump_id,incarnation,ticket_id,operation_id,binding_json,audio_state,metadata_state,state)
VALUES('fixture-other','inc','ticket-one','operation-one','{}','removed','absent','completed')"""),
    throwsA(isA<SqliteException>()),
  );
}

void main() {
  for (final version in [3, 4]) {
    test('v$version to v6 preserves every original column and queue row',
        () async {
      final sql = oldStorageDatabase(version);
      final before = sqlRows(sql, 'dumps');
      final queue = sqlRows(sql, 'sync_queue');
      final db = LocalDb.forTesting(NativeDatabase.opened(sql));
      addTearDown(db.close);
      expect(before, hasLength(10));
      expect(queue, hasLength(10));
      expect(sql.userVersion, version);
      await db.listDumps();
      expect(sql.userVersion, 19);
      final after = sqlRows(sql, 'dumps');
      expect(after, hasLength(before.length));
      for (var i = 0; i < before.length; i++) {
        expect(
          {for (final name in before[i].keys) name: after[i][name]},
          before[i],
        );
        if (version == 3) {
          final hasText =
              (before[i]['transcript'] as String?)?.trim().isNotEmpty ?? false;
          expect(
            after[i]['transcription_status'],
            hasText ? 'completed' : 'not_transcribed',
          );
          expect(after[i]['transcription_attempt'], 0);
          expect(
            after[i]['transcription_completed_at'],
            hasText ? before[i]['updated_at'] : null,
          );
          for (final name in [
            'transcription_request_id',
            'transcription_job_id',
            'transcription_started_at',
            'transcription_updated_at',
            'transcription_error',
            // v8: an upgraded recording arrives unfiled.
            'folder_id',
          ]) {
            expect(after[i][name], isNull);
          }
        }
      }
      expect(sqlRows(sql, 'sync_queue'), queue);
      final tables = sql
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'storage_locations',
          'storage_catalog_state',
          'recording_bindings',
          'capture_reservations',
          'local_deletion_batches',
          'local_deletion_tickets',
        ]),
      );
      expect(
        sql.select('SELECT * FROM storage_catalog_state').single['revision'],
        0,
      );
      expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');
      expect(sql.select('PRAGMA foreign_key_check'), isEmpty);
      sql.execute(
        "INSERT INTO dumps_fts(dumps_fts, rank) VALUES('integrity-check', 1)",
      );
      sql.execute(
        "UPDATE dumps SET title='Changed search token' WHERE id='fixture-0'",
      );
      expect(await db.searchDumps('Changed'), hasLength(1));
      // Synthetic SQL fixture only: verifies old FTS delete trigger, not app deletion.
      sql.execute("DELETE FROM sync_queue WHERE dump_id='fixture-0'");
      sql.execute("DELETE FROM dumps WHERE id='fixture-0'");
      expect(await db.searchDumps('Changed'), isEmpty);
      verifyCatalogSchema(sql);
    });
  }
  test('fresh v6 starts without a claimed legacy/default location', () async {
    final sql = sqlite3.openInMemory();
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();
    final state = await db
        .customSelect('SELECT * FROM storage_catalog_state')
        .getSingle();
    expect(state.data['default_location_id'], isNull);
    expect(state.data['bootstrap_version'], 0);
    verifyCatalogSchema(sql);
    await db.customStatement('UPDATE storage_catalog_state SET revision=7');
    await db.initializeStorageCatalogRows();
    expect(
      sql
          .select('SELECT revision FROM storage_catalog_state')
          .single['revision'],
      7,
    );
  });
  test('file-backed v4 upgrade and v6 reopen preserve rows and catalog state',
      () async {
    final dir =
        createResolvedTempSync('storage-migration-fixture-');
    final file = File('${dir.path}/fixture.sqlite');
    final sql = oldStorageDatabase(4, path: file.path);
    final before = sqlRows(sql, 'dumps');
    final queue = sqlRows(sql, 'sync_queue');
    sql.dispose();
    var db = LocalDb.forTesting(NativeDatabase(file));
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
    await db.listDumps();
    await db.customStatement('UPDATE storage_catalog_state SET revision=9');
    await db.close();
    db = LocalDb.forTesting(NativeDatabase(file));
    await db.listDumps();
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .data
          .values
          .single,
      19,
    );
    expect(
      (await db
              .customSelect('SELECT revision FROM storage_catalog_state')
              .getSingle())
          .data['revision'],
      9,
    );
    expect(
      (await db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .map(
            // v8 adds folder_id. Compare only the columns the fixture had, so
            // this stays an "existing data survived" assertion rather than a
            // schema snapshot that must be edited for every new column.
            (r) => <String, Object?>{
              for (final String name in before.first.keys) name: r.data[name],
            },
          )
          .toList(),
      before,
    );
    expect(
      (await db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .every((r) => r.data['folder_id'] == null),
      isTrue,
      reason: 'an upgraded recording must arrive unfiled, not in some folder',
    );
    expect(
      (await db.customSelect('SELECT * FROM sync_queue ORDER BY id').get())
          .map((r) => r.data)
          .toList(),
      queue,
    );
    expect(
      (await db.customSelect('PRAGMA integrity_check').getSingle())
          .data
          .values
          .single,
      'ok',
    );
  });
}
