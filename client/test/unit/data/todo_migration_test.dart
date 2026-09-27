// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import '../../support/storage_migration_fixture.dart';

/// v23 (To Do arc Phase 1): the todos table arrives.
const _todoColumns = [
  'id',
  'text',
  'done_at',
  'due_date',
  'source',
  'source_ref',
  'created_at',
  'updated_at',
  'deleted_at',
  // Client-only sync pair, mirroring notebooks: dirty until the server
  // confirms, and the seq the row was last reconciled at.
  'sync_dirty',
  'synced_seq',
];

List<Object?> _columnNames(Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name']).toList();

void main() {
  test('a fresh database is created at v23 with the todos table', () async {
    final sql = sqlite3.openInMemory();
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(db.schemaVersion, 23);
    expect(sql.userVersion, 23);
    expect(_columnNames(sql, 'todos'), _todoColumns);
    sql.execute(
      'INSERT INTO todos(id,text,created_at,updated_at) '
      "VALUES('t1','x','2026-09-27T00:00:00Z','2026-09-27T00:00:00Z')",
    );
    expect(
      () => sql.execute(
        'INSERT INTO todos(id,text,created_at,updated_at) '
        "VALUES('t1','y','2026-09-27T00:00:00Z','2026-09-27T00:00:00Z')",
      ),
      throwsA(isA<SqliteException>()),
      reason: 'id is the primary key',
    );
    expect(
      sql.select("SELECT source FROM todos WHERE id='t1'").single['source'],
      'manual',
      reason: 'source defaults to manual',
    );
  });

  test('upgrading an old database gains todos and preserves every dump row',
      () async {
    final sql = oldStorageDatabase(4);
    final before = sqlRows(sql, 'dumps');
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    expect(sql.userVersion, 4);

    await db.listDumps();

    expect(sql.userVersion, 23);
    expect(_columnNames(sql, 'todos'), _todoColumns);
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
  });

  test('the migration is guarded: a database that somehow already has a '
      'todos table upgrades without error and keeps its rows', () async {
    final sql = oldStorageDatabase(4);
    // Simulate a partial earlier run (or a sideways build) that created
    // the table before user_version caught up.
    sql.execute('''
      CREATE TABLE todos (
        id TEXT NOT NULL,
        text TEXT NOT NULL,
        done_at TEXT NULL,
        due_date TEXT NULL,
        source TEXT NOT NULL DEFAULT 'manual',
        source_ref TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT NULL,
        sync_dirty INTEGER NOT NULL DEFAULT 1,
        synced_seq INTEGER NULL,
        PRIMARY KEY (id)
      );
    ''');
    sql.execute(
      'INSERT INTO todos(id,text,created_at,updated_at) '
      "VALUES('kept','still here','2026-01-01T00:00:00Z',"
      "'2026-01-01T00:00:00Z')",
    );
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(sql.userVersion, 23);
    expect(
      sql.select("SELECT text FROM todos WHERE id='kept'").single['text'],
      'still here',
    );
  });
}
