// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
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
  // v24 (To Do folders, v1.24.0): the shared-folder link, declared last so
  // fresh and upgraded databases agree.
  'folder_id',
  // v25 (re-transcription guard, v1.28.0): LOCAL-ONLY fingerprint of the
  // voice parse that made the row. Never pushed, never read from a pull.
  'capture_fingerprint',
  // v29: user pin; nullable means old rows remain visually unpinned.
  'pinned',
  // v33: synced Kanban placement.
  'column_id',
  'board_order',
];

List<Object?> _columnNames(Database db, String table) =>
    db.select('PRAGMA table_info($table)').map((r) => r['name']).toList();

void main() {
  test('a fresh database is created at v33 with todos and columns', () async {
    final sql = sqlite3.openInMemory();
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(db.schemaVersion, 33);
    expect(sql.userVersion, 33);
    expect(_columnNames(sql, 'todos'), _todoColumns);
    expect(_columnNames(sql, 'todo_columns'), <String>[
      'id',
      'name',
      'sort_order',
      'created_at',
      'updated_at',
      'deleted_at',
      'sync_dirty',
      'synced_seq',
    ]);
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

  test(
    'upgrading an old database gains todos and preserves every dump row',
      () async {
    final sql = oldStorageDatabase(4);
    final before = sqlRows(sql, 'dumps');
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    expect(sql.userVersion, 4);

    await db.listDumps();

    expect(sql.userVersion, 34);
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
    },
  );

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

    expect(sql.userVersion, 33);
    expect(_columnNames(sql, 'todos'), _todoColumns);
    expect(
      sql.select("SELECT text FROM todos WHERE id='kept'").single['text'],
      'still here',
    );
  });

  test('v23 -> v24 adds a null folder_id and keeps every todo row', () async {
    final sql = oldStorageDatabase(4);
    // A v23 todos table exactly as Phase 1 created it (no folder_id).
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
      'INSERT INTO todos(id,text,due_date,created_at,updated_at) '
      "VALUES('a','milk','2026-10-01','2026-01-01T00:00:00Z',"
      "'2026-01-01T00:00:00Z'),"
      "('b','eggs',NULL,'2026-01-02T00:00:00Z','2026-01-02T00:00:00Z')",
    );
    sql.userVersion = 23;
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(sql.userVersion, 33);
    expect(_columnNames(sql, 'todos'), _todoColumns);
    final rows = sql.select(
      'SELECT id, text, due_date, folder_id FROM todos '
      'ORDER BY id',
    );
    expect(rows.length, 2, reason: 'no row is lost by the upgrade');
    expect(rows[0]['text'], 'milk');
    expect(rows[0]['due_date'], '2026-10-01');
    expect(rows[0]['folder_id'], isNull);
    expect(rows[1]['text'], 'eggs');
    expect(rows[1]['folder_id'], isNull);
  });

  test(
    'v24 -> v25 adds a null capture_fingerprint and changes no data',
      () async {
    final sql = oldStorageDatabase(4);
    // A v24 todos table exactly as v1.24.0 left it (folder_id, no
    // capture_fingerprint).
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
        folder_id TEXT NULL,
        PRIMARY KEY (id)
      );
    ''');
    sql.execute(
      'INSERT INTO todos(id,text,due_date,source,source_ref,created_at,'
      'updated_at,sync_dirty,folder_id) '
      "VALUES('a','milk','2026-10-01','voice','dump-1',"
      "'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',0,'f1'),"
      "('b','eggs',NULL,'manual',NULL,'2026-01-02T00:00:00Z',"
      "'2026-01-02T00:00:00Z',1,NULL)",
    );
    sql.userVersion = 24;
    final before = sqlRows(sql, 'todos');
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await db.listDumps();

    expect(sql.userVersion, 34);
    expect(_columnNames(sql, 'todos'), _todoColumns);
    final rows = sqlRows(sql, 'todos');
    expect(rows.length, 2, reason: 'no row is lost by the upgrade');
    for (final Map<String, Object?> row in rows) {
      expect(row['capture_fingerprint'], isNull);
    }
    expect(
      rows
          .map(
            (Map<String, Object?> row) => <String, Object?>{
                for (final String name in before.first.keys)
                  if (name != 'sync_dirty') name: row[name],
            },
          )
          .toList(),
        before
            .map(
              (Map<String, Object?> row) => <String, Object?>{
                for (final String name in row.keys)
                  if (name != 'sync_dirty') name: row[name],
              },
            )
            .toList(),
        reason: 'the board reference is the only data change',
      );
      expect(
        rows.map((row) => row['sync_dirty']),
        everyElement(1),
        reason: 'the newly assigned column reference must sync',
      );
    },
    );

  test('v24 -> v25 is guarded when the column already exists', () async {
    final sql = oldStorageDatabase(4);
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
        folder_id TEXT NULL,
        capture_fingerprint TEXT NULL,
        PRIMARY KEY (id)
      );
    ''');
    sql.userVersion = 24;
    final db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);

    await expectLater(db.listDumps(), completes);

    expect(sql.userVersion, 33);
    expect(_columnNames(sql, 'todos'), _todoColumns);
  });

  test(
    'oldest supported upgrade seeds columns and assigns every old todo',
    () async {
      final Database sql = oldStorageDatabase(4);
      sql.execute('''
      CREATE TABLE todos (
        id TEXT NOT NULL PRIMARY KEY,
        text TEXT NOT NULL,
        done_at TEXT NULL,
        due_date TEXT NULL,
        source TEXT NOT NULL DEFAULT 'manual',
        source_ref TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT NULL,
        sync_dirty INTEGER NOT NULL DEFAULT 0,
        synced_seq INTEGER NULL
      )
    ''');
      sql.execute(
        "INSERT INTO todos VALUES ('old','kept',NULL,NULL,'manual',NULL,"
        "'2025-01-01T00:00:00Z','2025-01-01T00:00:00Z',NULL,0,7)",
      );
      sql.userVersion = 23;
      final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
      addTearDown(db.close);

      await db.listDumps();

      expect(sql.userVersion, 33);
      expect(
        sql
            .select(
              'SELECT id,name,sort_order FROM todo_columns '
              'WHERE deleted_at IS NULL ORDER BY sort_order',
            )
            .map((row) => <Object?>[row['id'], row['name'], row['sort_order']])
            .toList(),
        <List<Object?>>[
          <Object?>['todo-column-todo', 'To Do', 0],
          <Object?>['todo-column-progress', 'In Progress', 1],
          <Object?>['todo-column-done', 'Done', 2],
        ],
      );
      final Row row = sql
          .select(
            "SELECT text,column_id,board_order,sync_dirty FROM todos WHERE id='old'",
          )
          .single;
      expect(row['text'], 'kept');
      expect(row['column_id'], defaultTodoColumnId);
      expect(row['board_order'], isNonNegative);
      expect(row['sync_dirty'], 1, reason: 'the new reference must sync');
    },
  );
}
