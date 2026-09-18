// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v6 -> v7 upgrade on a database that already has a user's work in it.
///
/// A fresh schema passing its own tests proves nothing about an existing
/// install: the risk is the upgrade path, where a notebook someone has been
/// writing in for months meets a new column. This builds a genuine v6
/// database with a notebook in it, opens it as v7, and checks the work
/// survived.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v6 database with a notebook upgrades to v7 without losing it',
      () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();

    // The v6 shape of the notebooks table: no folder_id. A real v6 database
    // also has dumps, and the v8 step inspects it, so the fixture carries it.
    raw.execute('''
      CREATE TABLE dumps (
        id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        mode TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL,
        title TEXT NOT NULL,
        audio_path TEXT NOT NULL,
        audio_size_bytes INTEGER NOT NULL,
        sync_status TEXT NOT NULL,
        PRIMARY KEY (id)
      );
    ''');
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        doc_json TEXT NOT NULL,
        ink_json TEXT NOT NULL,
        PRIMARY KEY (id)
      );
    ''');
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json) VALUES (\'nb-old\', \'Months of notes\', 100, 200, '
      '\'{"blocks":[]}\', \'{"strokes":[]}\');',
    );
    raw.execute('PRAGMA user_version = 6;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Opening runs the migration.
    final List<NotebookRow> rows = await db.select(db.notebooks).get();

    expect(rows, hasLength(1), reason: 'the existing notebook must survive');
    expect(rows.single.id, 'nb-old');
    expect(rows.single.title, 'Months of notes');
    expect(
      rows.single.docJson,
      '{"blocks":[]}',
      reason: 'content must be carried across untouched',
    );
    expect(
      rows.single.folderId,
      isNull,
      reason: 'an existing notebook lands unfiled, not in some default folder',
    );

    // And the new table exists and is empty.
    expect(await db.select(db.folders).get(), isEmpty);

    // The upgraded database is fully usable: file the old notebook.
    final String folderId = await db.createFolder(name: 'Archive');
    await db.moveNotebookToFolder(notebookId: 'nb-old', folderId: folderId);
    final NotebookRow filed = await (db.select(db.notebooks)
          ..where((t) => t.id.equals('nb-old')))
        .getSingle();
    expect(filed.folderId, folderId);
  });

  // The upgrade that actually broke. A database from before notebooks existed
  // creates the notebooks table during the v6 step — and createTable builds
  // from the CURRENT definition, so the table is born with folder_id already
  // on it. Adding the column again threw "duplicate column name" and left the
  // app unable to open its own database on launch.
  test('a pre-notebooks database upgrades straight to v7 without colliding',
      () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();

    // A v5 database: dumps exist, notebooks do not.
    raw.execute('''
      CREATE TABLE dumps (
        id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (id)
      );
    ''');
    raw.execute("INSERT INTO dumps (id, created_at) VALUES ('d-1', 10);");
    raw.execute('PRAGMA user_version = 5;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Opening must not throw: this is the launch path for an existing install.
    final List<NotebookRow> notebooks = await db.select(db.notebooks).get();
    expect(notebooks, isEmpty);
    expect(await db.select(db.folders).get(), isEmpty);

    // And the new column is usable, not merely absent-but-declared.
    final String folderId = await db.createFolder(name: 'Work');
    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'nb-new',
            title: 'Fresh',
            createdAt: 1,
            updatedAt: 1,
            docJson: '{}',
            inkJson: '{}',
          ),
        );
    await db.moveNotebookToFolder(notebookId: 'nb-new', folderId: folderId);
    final NotebookRow row = await (db.select(db.notebooks)
          ..where((t) => t.id.equals('nb-new')))
        .getSingle();
    expect(row.folderId, folderId);
  });
}
