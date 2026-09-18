// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// Filing for recordings and text notes, schema v7 -> v8.
///
/// Notebooks proved the pattern; dumps use the same nullable folder_id so one
/// folder holds both a notebook and the recordings that belong with it.
///
/// Unlike notebooks, the dumps table has existed since v1 and is never
/// re-created during an upgrade, so there is no "duplicate column name" trap
/// here — but the upgrade is still tested from a real old database rather than
/// assumed, because that is exactly the assumption that broke last time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDb db;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> insertDump(String id) async {
    await db.customStatement(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, audio_path, audio_size_bytes, sync_status) VALUES '
      '(\'$id\', 1, 1, \'brain_dump\', 5, \'Title $id\', \'/tmp/$id.opus\', 10, '
      '\'local_only\')',
    );
    return id;
  }

  Future<String?> folderOf(String id) async {
    final row = await db
        .customSelect("SELECT folder_id FROM dumps WHERE id = '$id'")
        .getSingle();
    return row.data['folder_id'] as String?;
  }

  group('dump folders', () {
    test('every folder gets a distinct id', () async {
      // A hardcoded or non-interpolated id silently collides: the second
      // folder overwrites the first, and notebooks filed in one appear in
      // the other. Caught in review when a probe printed the raw id.
      final String a = await db.createFolder(name: 'Work');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final String b = await db.createFolder(name: 'Home');

      expect(a, isNot(b), reason: 'folder ids must be unique');
      expect(
        a,
        isNot(contains(r'$')),
        reason: 'an uninterpolated id string means every folder shares one id',
      );
      expect(await db.select(db.folders).get(), hasLength(2));
    });

    test('a recording starts unfiled', () async {
      await insertDump('d-1');
      expect(await folderOf('d-1'), isNull);
    });

    test('a recording can be filed and unfiled', () async {
      final String folderId = await db.createFolder(name: 'Work');
      await insertDump('d-1');

      await db.moveDumpToFolder(dumpId: 'd-1', folderId: folderId);
      expect(await folderOf('d-1'), folderId);

      await db.moveDumpToFolder(dumpId: 'd-1', folderId: null);
      expect(await folderOf('d-1'), isNull);
    });

    test('deleting a folder unfiles its recordings and keeps them', () async {
      // Two folders, and the recording is in the SECOND one. With a single
      // folder the assertion passes even if deleteFolder ignores dumps
      // entirely, because 'is it null' cannot tell "unfiled correctly" from
      // "never filed". The survivor proves only the target was touched.
      final String other = await db.createFolder(name: 'Archive');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final String folderId = await db.createFolder(name: 'Work');
      await insertDump('d-1');
      await insertDump('d-keep');
      await db.moveDumpToFolder(dumpId: 'd-1', folderId: folderId);
      await db.moveDumpToFolder(dumpId: 'd-keep', folderId: other);

      expect(await folderOf('d-1'), folderId);

      await db.deleteFolder(folderId);

      final rows = await db.customSelect('SELECT id FROM dumps').get();
      expect(
        rows,
        hasLength(2),
        reason: 'deleting a folder must never destroy a recording',
      );
      expect(
        await folderOf('d-1'),
        isNull,
        reason: 'the deleted folder must release its recordings',
      );
      expect(
        await folderOf('d-keep'),
        other,
        reason: 'recordings in other folders must not be disturbed',
      );
    });

    test('deleting a folder unfiles notebooks AND recordings together',
        () async {
      final String folderId = await db.createFolder(name: 'Work');
      await insertDump('d-1');
      await db.moveDumpToFolder(dumpId: 'd-1', folderId: folderId);
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Notes',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );
      await db.moveNotebookToFolder(notebookId: 'nb-1', folderId: folderId);

      await db.deleteFolder(folderId);

      expect(await folderOf('d-1'), isNull);
      final NotebookRow nb = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-1')))
          .getSingle();
      expect(
        nb.folderId,
        isNull,
        reason: 'one folder holds both kinds; deleting it must unfile both',
      );
    });

    test('renaming a dump keeps it in its folder', () async {
      final String folderId = await db.createFolder(name: 'Work');
      await insertDump('d-1');
      await db.moveDumpToFolder(dumpId: 'd-1', folderId: folderId);

      await db.renameDump(dumpId: 'd-1', title: 'Client call');

      expect(
        await folderOf('d-1'),
        folderId,
        reason: 'a rename must not unfile the recording',
      );
      final row = await db
          .customSelect("SELECT title FROM dumps WHERE id = 'd-1'")
          .getSingle();
      expect(row.data['title'], 'Client call');
    });
  });

  test('a v7 database with a filed notebook upgrades to v8 intact', () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();

    // v7 shape: dumps without folder_id, notebooks WITH it, folders present.
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
      CREATE TABLE folders (
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
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
        folder_id TEXT NULL,
        PRIMARY KEY (id)
      );
    ''');
    raw.execute(
      'INSERT INTO folders (id, name, created_at) VALUES (\'f-1\', \'Work\', 5);',
    );
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json, folder_id) VALUES (\'nb-1\', \'Filed\', 1, 2, \'{}\', \'{}\', \'f-1\');',
    );
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, audio_path, audio_size_bytes, sync_status) VALUES '
      '(\'d-1\', 1, 1, \'brain_dump\', 5, \'Old recording\', \'/tmp/d.opus\', 10, '
      '\'local_only\');',
    );
    raw.execute('PRAGMA user_version = 7;');

    final LocalDb upgraded = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(upgraded.close);

    // Opening runs the migration and must not throw.
    final rows = await upgraded.customSelect('SELECT * FROM dumps').get();
    expect(rows, hasLength(1));
    expect(rows.single.data['title'], 'Old recording');
    expect(
      rows.single.data['folder_id'],
      isNull,
      reason: 'existing recordings arrive unfiled, not in a default folder',
    );

    // Existing filing on notebooks survives untouched.
    final NotebookRow nb = await (upgraded.select(upgraded.notebooks)
          ..where((t) => t.id.equals('nb-1')))
        .getSingle();
    expect(nb.folderId, 'f-1');
  });
}
