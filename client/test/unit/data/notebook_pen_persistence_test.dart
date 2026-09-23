// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pen memory and ruling must survive the REAL repository — an in-memory
// fake proves the editor's intent, but only a round trip through drift
// proves the row actually carries the columns. saveNotebook's UPDATE
// historically dropped `ruling` on the floor (a latent bug found while
// adding pen memory): cycling the ruling then reopening lost the choice.
// These tests pin both columns through the genuine SQL path.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/models/notebook_ruling.dart';

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

  test('saveNotebook persists the nib through the real database', () async {
    final Notebook created = await repository.createNotebook(title: 'Pens');
    await repository.saveNotebook(
      created.copyWith(lastPenStyle: PenStyle.ballpoint),
    );

    final Notebook? reread = await repository.getNotebook(created.id);
    expect(
      reread?.lastPenStyle,
      PenStyle.ballpoint,
      reason: 'the nib must survive a save/reopen round trip in SQL, '
          'not just in an in-memory fake',
    );
  });

  test('saveNotebook persists a ruling change (the latent v10 bug)',
      () async {
    final Notebook created = await repository.createNotebook(title: 'Rules');
    await repository.saveNotebook(
      created.copyWith(ruling: NotebookRuling.small),
    );

    final Notebook? reread = await repository.getNotebook(created.id);
    expect(
      reread?.ruling,
      NotebookRuling.small,
      reason: "saveNotebook's UPDATE must write the ruling column — it "
          'historically did not, so a cycled ruling vanished on reopen',
    );
  });

  test('a notebook that never recorded a nib rereads as null', () async {
    final Notebook created = await repository.createNotebook(title: 'Fresh');
    await repository.saveNotebook(created);

    final Notebook? reread = await repository.getNotebook(created.id);
    expect(
      reread?.lastPenStyle,
      isNull,
      reason: 'never-recorded stays null so the editor, not the row, '
          'chooses the fountain default',
    );
  });
}
