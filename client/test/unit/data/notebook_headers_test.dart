// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The notebooks LIST must be cheap. `watchNotebooks()` decodes every
// stroke of every notebook on every table write — cost that grows with
// everything the user has ever drawn, paid while the list screen sits
// under the editor during pop animations. The list needs only metadata,
// so the repository offers a header stream carrying exactly that.
//
// NotebookListEntry deliberately has NO document and NO ink: a list row
// cannot be copyWith-ed into a save that hollows a notebook out. Actions
// needing content (rename, export) must fetch the full notebook first.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';

void main() {
  late LocalDb db;
  late DateTime now;
  var ids = 0;

  NotebookRepository build() => NotebookRepository(
        db: db,
        idFactory: () => 'notebook-${++ids}',
        now: () => now,
      );

  setUp(() {
    ids = 0;
    now = DateTime.utc(2026, 9, 23, 9, 30);
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('headers carry the list metadata, newest-updated first', () async {
    final NotebookRepository repository = build();
    final Notebook first = await repository.createNotebook(title: 'First');
    now = now.add(const Duration(minutes: 1));
    await repository.createNotebook(title: 'Second');

    List<NotebookListEntry> rows =
        await repository.watchNotebookHeaders().first;
    expect(rows.map((NotebookListEntry e) => e.title).toList(), <String>[
      'Second',
      'First',
    ]);
    expect(rows.last.id, first.id);
    expect(rows.last.updatedAt, first.updatedAt);
    expect(rows.last.folderId, isNull);

    // The stream is live: a save re-sorts, a delete removes.
    now = now.add(const Duration(minutes: 5));
    await repository.saveNotebook(first.copyWith(title: 'First again'));
    rows = await repository
        .watchNotebookHeaders()
        .firstWhere((List<NotebookListEntry> r) => r.first.id == first.id);
    expect(rows.first.title, 'First again');

    await repository.deleteNotebook(first.id);
    rows = await repository
        .watchNotebookHeaders()
        .firstWhere((List<NotebookListEntry> r) => r.length == 1);
    expect(rows.single.title, 'Second');
  });
}
