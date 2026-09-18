// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

/// Folders, schema v6 -> v7.
///
/// Folders are metadata, not directories: a nullable `folder_id` on the rows
/// that can be filed. Tangent's durable publication layer (SAF on Android)
/// is the most defect-prone code in the repo, and making folders physical
/// would mean moving published files between directories on every
/// reorganise — a rename storm across storage that can half-fail. A column
/// moves nothing on disk, and it maps onto sync as one more per-entity field.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDb db;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('folders schema', () {
    test('a folder can be created and read back', () async {
      final String id = await db.createFolder(name: 'Work');
      final List<Folder> folders = await db.select(db.folders).get();

      expect(folders, hasLength(1));
      expect(folders.single.id, id);
      expect(folders.single.name, 'Work');
      expect(
        folders.single.createdAt,
        greaterThan(0),
        reason: 'folders need a creation time for stable ordering',
      );
    });

    test('notebooks start with no folder', () async {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Loose notebook',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );

      final NotebookRow row = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-1')))
          .getSingle();

      expect(
        row.folderId,
        isNull,
        reason: 'existing notebooks must survive the migration unfiled',
      );
    });

    test('a notebook can be filed into a folder', () async {
      final String folderId = await db.createFolder(name: 'Work');
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Sprint ideas',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );

      await db.moveNotebookToFolder(notebookId: 'nb-1', folderId: folderId);

      final NotebookRow row = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-1')))
          .getSingle();
      expect(row.folderId, folderId);
    });

    test('a notebook can be moved back out to no folder', () async {
      final String folderId = await db.createFolder(name: 'Work');
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Sprint ideas',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );
      await db.moveNotebookToFolder(notebookId: 'nb-1', folderId: folderId);

      await db.moveNotebookToFolder(notebookId: 'nb-1', folderId: null);

      final NotebookRow row = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-1')))
          .getSingle();
      expect(row.folderId, isNull);
    });

    test('deleting a folder unfiles its notebooks and never deletes them',
        () async {
      final String folderId = await db.createFolder(name: 'Work');
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Sprint ideas',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );
      await db.moveNotebookToFolder(notebookId: 'nb-1', folderId: folderId);

      await db.deleteFolder(folderId);

      final List<NotebookRow> notebooks = await db.select(db.notebooks).get();
      expect(
        notebooks,
        hasLength(1),
        reason: 'deleting a folder must never destroy the work inside it',
      );
      expect(notebooks.single.folderId, isNull);
      expect(await db.select(db.folders).get(), isEmpty);
    });

    test('a folder can be renamed', () async {
      final String folderId = await db.createFolder(name: 'Work');

      await db.renameFolder(folderId: folderId, name: 'Client work');

      final Folder row = await (db.select(db.folders)
            ..where((t) => t.id.equals(folderId)))
          .getSingle();
      expect(row.name, 'Client work');
    });

    test('folders are watchable so the list updates live', () async {
      final Future<List<Folder>> first = db.watchFolders().first;
      await db.createFolder(name: 'Work');

      expect((await first), isA<List<Folder>>());

      final List<Folder> after = await db.watchFolders().first;
      expect(after.map((Folder f) => f.name), contains('Work'));
    });
  });
}
