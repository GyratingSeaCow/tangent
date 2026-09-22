// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import '../../support/storage_migration_fixture.dart';

const _notebookColumns = [
  'id',
  'title',
  'created_at',
  'updated_at',
  'doc_json',
  'ink_json',
  // v7: folders are metadata, so filing a notebook is a column, not a move.
  'folder_id',
  // v9: multi-device sync. sync_dirty tracks unsynced local edits; synced_seq
  // records the server sequence the row was last reconciled at.
  // v10: page ruling, stored as the enum's name. Nullable — null reads as
  // blank, which is how every page rendered before this column existed.
  // Declared right after folder_id, so it precedes the sync pair.
  'ruling',
  'sync_dirty',
  'synced_seq',
  // v13: notebook trash. Deletion parks the row here for 7 days before
  // purge, so a synced-in (or fat-fingered) delete is recoverable.
  'deleted_at',
];

const _insertNotebook =
    'INSERT INTO notebooks(id,title,created_at,updated_at,doc_json,ink_json) '
    "VALUES('n1','T',1,2,'{}','{}')";

List<Object?> _columnNames(Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name']).toList();

void main() {
  test('a fresh database is created at the current schema with notebooks',
      () async {
    final sql = sqlite3.openInMemory();
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(db.schemaVersion, 15);
    expect(sql.userVersion, 15);
    expect(_columnNames(sql, 'notebooks'), _notebookColumns);
    expect(
      sql.select('PRAGMA foreign_key_list(notebooks)'),
      isEmpty,
      reason: 'Notebooks must never cascade with dumps',
    );
    sql.execute(_insertNotebook);
    expect(
      () => sql.execute(_insertNotebook),
      throwsA(isA<SqliteException>()),
      reason: 'id is the primary key',
    );
  });

  test('upgrading a v4 database adds notebooks and preserves every dump row',
      () async {
    final sql = oldStorageDatabase(4);
    final before = sqlRows(sql, 'dumps');
    final queue = sqlRows(sql, 'sync_queue');
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    expect(sql.userVersion, 4);

    await db.listDumps();

    expect(sql.userVersion, 15);
    expect(_columnNames(sql, 'notebooks'), _notebookColumns);
    // v8 adds folder_id to dumps, so compare the columns the fixture had:
    // this test is about existing rows surviving, not about the column list.
    expect(
      sqlRows(sql, 'dumps')
          .map(
            (Map<String, Object?> row) => <String, Object?>{
              for (final String name in before.first.keys) name: row[name],
            },
          )
          .toList(),
      before,
    );
    expect(
      sqlRows(sql, 'dumps').every((row) => row['folder_id'] == null),
      isTrue,
      reason: 'an upgraded recording must arrive unfiled',
    );
    expect(sqlRows(sql, 'sync_queue'), queue);
    expect(sql.select('SELECT * FROM notebooks'), isEmpty);
    expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(sql.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('the v5 to v6 step creates notebooks and touches nothing else',
      () async {
    final dir = Directory.systemTemp.createTempSync('notebook-migration-');
    final file = File('${dir.path}/fixture.sqlite');
    final fixture = oldStorageDatabase(4, path: file.path);
    fixture.dispose();

    var db = LocalDb.forTesting(NativeDatabase(file));
    await db.listDumps();
    await db.customStatement('UPDATE storage_catalog_state SET revision=9');
    await db.close();

    // Rewind to a genuine v5 database: the storage catalog from the v4 -> v5
    // step stays, the notebooks table does not exist yet.
    var sql = sqlite3.open(file.path);
    sql.execute('DROP TABLE notebooks');
    sql.userVersion = 5;
    final before = sqlRows(sql, 'dumps');
    final queue = sqlRows(sql, 'sync_queue');
    final locations = sqlRows(sql, 'storage_locations');
    sql.dispose();

    db = LocalDb.forTesting(NativeDatabase(file));
    addTearDown(() => dir.deleteSync(recursive: true));
    await db.listDumps();
    await db.close();

    sql = sqlite3.open(file.path);
    addTearDown(sql.dispose);
    expect(sql.userVersion, 15);
    expect(_columnNames(sql, 'notebooks'), _notebookColumns);
    // v8 adds folder_id to dumps, so compare the columns the fixture had:
    // this test is about existing rows surviving, not about the column list.
    expect(
      sqlRows(sql, 'dumps')
          .map(
            (Map<String, Object?> row) => <String, Object?>{
              for (final String name in before.first.keys) name: row[name],
            },
          )
          .toList(),
      before,
    );
    expect(
      sqlRows(sql, 'dumps').every((row) => row['folder_id'] == null),
      isTrue,
      reason: 'an upgraded recording must arrive unfiled',
    );
    expect(sqlRows(sql, 'sync_queue'), queue);
    expect(sqlRows(sql, 'storage_locations'), locations);
    expect(
      sql.select('SELECT revision FROM storage_catalog_state').single['revision'],
      9,
      reason: 'The v6 step must not re-run catalog bootstrap',
    );
    expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');
  });

  test('the v14 step re-pushes existing filings and nothing else', () async {
    // Build a current-schema database, then wind the version back to 13 and
    // reopen: the v14 data-only step must run against these rows.
    final sql = sqlite3.openInMemory();
    final seed = LocalDb.forTesting(
      NativeDatabase.opened(sql, closeUnderlyingOnClose: false),
    );
    await seed.listDumps();
    await seed.close();
    sql.execute(
      'INSERT INTO folders(id, name, created_at, sync_dirty) '
      "VALUES('f1','Field Notes',1,0)",
    );
    sql.execute(
      'INSERT INTO notebooks'
      '(id,title,created_at,updated_at,doc_json,ink_json,folder_id,'
      'sync_dirty,deleted_at) VALUES '
      "('filed','A',1,2,'{}','{}','f1',0,NULL),"
      "('unfiled','B',1,2,'{}','{}',NULL,0,NULL),"
      "('trashed','C',1,2,'{}','{}','f1',0,5)",
    );
    sql.userVersion = 13;

    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();

    expect(sql.userVersion, 15);
    final rows = <String, int>{
      for (final r in sql.select('SELECT id, sync_dirty FROM notebooks'))
        r['id'] as String: r['sync_dirty'] as int,
    };
    expect(
      rows['filed'],
      1,
      reason: 'a pre-folder-sync filing must push once so peers learn it',
    );
    expect(rows['unfiled'], 0, reason: 'nothing to re-announce');
    expect(
      rows['trashed'],
      0,
      reason: 'pushing a trashed body would resurrect it on the peer',
    );
  });
}
