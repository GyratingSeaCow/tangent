// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';

/// Filing must survive every write path, or a folder silently empties itself.
///
/// Two paths can overwrite a notebook row: an ordinary edit (`saveNotebook`)
/// and durable adoption (`upsertNotebook`, which re-imports a notebook from
/// its published file). Neither carries a folder in its payload, so either
/// could quietly reset folder_id to null — the user files twenty notebooks,
/// writes one word in each, and finds the folder empty.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDb db;
  late NotebookRepository repository;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    repository = NotebookRepository(db: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String?> folderOf(String id) async {
    final NotebookRow row = await (db.select(db.notebooks)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    return row.folderId;
  }

  test('editing a filed notebook keeps it in its folder', () async {
    final String folderId = await db.createFolder(name: 'Work');
    final Notebook notebook = await repository.createNotebook(title: 'Sprint');
    await db.moveNotebookToFolder(
      notebookId: notebook.id,
      folderId: folderId,
    );

    await repository.saveNotebook(notebook.copyWith(title: 'Sprint planning'));

    expect(
      await folderOf(notebook.id),
      folderId,
      reason: 'an ordinary edit must not unfile the notebook',
    );
  });

  test('durable adoption keeps a filed notebook in its folder', () async {
    final String folderId = await db.createFolder(name: 'Work');
    final Notebook notebook = await repository.createNotebook(title: 'Sprint');
    await db.moveNotebookToFolder(
      notebookId: notebook.id,
      folderId: folderId,
    );

    // Re-import the same notebook from its published file.
    await repository.upsertNotebook(notebook);

    expect(
      await folderOf(notebook.id),
      folderId,
      reason: 're-importing a notebook must not unfile it',
    );
  });

  test('the repository reports which folder a notebook is in', () async {
    final String folderId = await db.createFolder(name: 'Work');
    final Notebook notebook = await repository.createNotebook(title: 'Sprint');
    await db.moveNotebookToFolder(
      notebookId: notebook.id,
      folderId: folderId,
    );

    final Notebook? loaded = await repository.getNotebook(notebook.id);
    expect(loaded?.folderId, folderId);

    final List<Notebook> all = await repository.watchNotebooks().first;
    expect(all.single.folderId, folderId);
  });
}
