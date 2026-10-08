// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';

/// To Do arc Phase 1: repository round trips against real SQL.
///
/// Every write must stamp `updated_at` and mark the row dirty — a write
/// that forgot the flag would be invisible to the user's other devices.
void main() {
  late LocalDb db;
  late TodoRepository repo;
  late DateTime clock;
  int ids = 0;

  Future<TodoRow> rowOf(String id) async => (await db.getTodoRow(id))!;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    clock = DateTime.utc(2026, 9, 27, 12);
    ids = 0;
    repo = TodoRepository(
      db: db,
      idFactory: () => 'todo-${++ids}',
      now: () => clock,
    );
  });

  tearDown(() => db.close());

  test('add stores an open, dirty row with stamped timestamps', () async {
    final TodoRow added = await repo.add('buy thermal paste');

    final TodoRow row = await rowOf(added.id);
    expect(row.body, 'buy thermal paste');
    expect(row.doneAt, isNull);
    expect(row.dueDate, isNull);
    expect(row.source, 'manual');
    expect(row.sourceRef, isNull);
    expect(row.deletedAt, isNull);
    expect(row.createdAt, clock.toIso8601String());
    expect(row.updatedAt, clock.toIso8601String());
    expect(row.syncDirty, isTrue);
  });

  test('add with a due date stores the bare ISO date', () async {
    final TodoRow added = await repo.add('call Dan', dueDate: '2026-09-30');
    expect((await rowOf(added.id)).dueDate, '2026-09-30');
  });

  test('toggle stamps done_at, toggle again clears it', () async {
    final TodoRow added = await repo.add('email the customer back');
    clock = clock.add(const Duration(minutes: 5));

    await repo.toggle(added.id);
    TodoRow row = await rowOf(added.id);
    expect(row.doneAt, clock.toIso8601String());
    expect(row.updatedAt, clock.toIso8601String());
    expect(row.syncDirty, isTrue);

    clock = clock.add(const Duration(minutes: 1));
    await repo.toggle(added.id);
    row = await rowOf(added.id);
    expect(row.doneAt, isNull, reason: 'unchecking clears done_at');
    expect(row.updatedAt, clock.toIso8601String());
  });

  test('editText rewrites the text and bumps updated_at', () async {
    final TodoRow added = await repo.add('tpyo');
    clock = clock.add(const Duration(seconds: 30));

    await repo.editText(added.id, 'typo, fixed');

    final TodoRow row = await rowOf(added.id);
    expect(row.body, 'typo, fixed');
    expect(row.updatedAt, clock.toIso8601String());
    expect(row.syncDirty, isTrue);
  });

  test('a cleared due date and a never-set one are both null on the row, '
      'but the clear still bumps updated_at so peers converge', () async {
    final TodoRow neverSet = await repo.add('someday item');
    final TodoRow dated = await repo.add('dated item', dueDate: '2026-10-01');
    final String datedStampBefore = (await rowOf(dated.id)).updatedAt;

    clock = clock.add(const Duration(minutes: 2));
    await repo.setDueDate(dated.id, null);

    final TodoRow cleared = await rowOf(dated.id);
    expect(cleared.dueDate, isNull);
    expect((await rowOf(neverSet.id)).dueDate, isNull);
    expect(
      cleared.updatedAt,
      isNot(datedStampBefore),
      reason: 'the clear is a real write that must travel',
    );
    expect(cleared.updatedAt, clock.toIso8601String());
  });

  test('softDelete hides the row from the watch stream; restore brings it '
      'back verbatim', () async {
    final TodoRow added = await repo.add('do not lose me');
    clock = clock.add(const Duration(minutes: 1));

    await repo.softDelete(added.id);
    TodoRow row = await rowOf(added.id);
    expect(row.deletedAt, clock.toIso8601String(), reason: 'soft, not gone');
    expect(await repo.watchTodos().first, isEmpty);

    clock = clock.add(const Duration(seconds: 3));
    await repo.restore(added.id);
    row = await rowOf(added.id);
    expect(row.deletedAt, isNull);
    expect(row.body, 'do not lose me');
    expect(row.syncDirty, isTrue);
    expect((await repo.watchTodos().first).single.id, added.id);
  });

  test('watchTodos excludes deleted rows and keeps entry order', () async {
    final TodoRow a = await repo.add('first');
    clock = clock.add(const Duration(seconds: 1));
    final TodoRow b = await repo.add('second');
    clock = clock.add(const Duration(seconds: 1));
    final TodoRow c = await repo.add('third');
    await repo.softDelete(b.id);

    final List<TodoRow> visible = await repo.watchTodos().first;
    expect(visible.map((t) => t.id).toList(), <String>[a.id, c.id]);
  });

  test('first add seeds three columns and assigns the default', () async {
    final TodoRow todo = await repo.add('assigned');
    final List<TodoColumnRow> columns = await repo.listColumns();

    expect(columns.map((c) => c.name), <String>[
      'To Do',
      'In Progress',
      'Done',
    ]);
    expect(todo.columnId, defaultTodoColumnId);
    expect(todo.boardOrder, 0);
  });

  test(
    'moveOnBoard moves across columns and reorders within a column',
    () async {
      final TodoRow a = await repo.add('a');
      final TodoRow b = await repo.add('b');
      final TodoRow c = await repo.add('c');
      final String progress = (await repo.listColumns())[1].id;

      await repo.moveOnBoard(b.id, progress, 0);
      await repo.moveOnBoard(c.id, defaultTodoColumnId, 0);

      expect((await rowOf(b.id)).columnId, progress);
      final List<TodoRow> first =
          (await repo.listTodos())
              .where((row) => row.columnId == defaultTodoColumnId)
              .toList()
            ..sort((x, y) => x.boardOrder.compareTo(y.boardOrder));
      expect(first.map((row) => row.id), <String>[c.id, a.id]);
      expect(first.map((row) => row.boardOrder), <int>[0, 1]);
    },
  );

  test(
    'explicit board placements spend migration markers atomically',
    () async {
      final TodoRow dragged = await repo.add('dragged');
      final TodoRow rehomedByDelete = await repo.add('rehomed by delete');
      final TodoRow sameSlot = await repo.add('dropped onto its own slot');
      final List<TodoColumnRow> columns = await repo.listColumns();
      final String progress = columns[1].id;
      final String done = columns[2].id;
      await db.customStatement(
        'INSERT INTO settings(key,value) VALUES(?,?),(?,?),(?,?)',
        <Object?>[
          'todo_kanban_backfill:${dragged.id}',
          '0',
          'todo_kanban_backfill:${rehomedByDelete.id}',
          '1',
          'todo_kanban_backfill:${sameSlot.id}',
          '2',
        ],
      );

      await repo.moveOnBoard(sameSlot.id, defaultTodoColumnId, 2);
      expect(await db.pendingTodoBoardOrder(sameSlot.id), isNull);

      await repo.moveOnBoard(dragged.id, progress, 0);
      expect(await db.pendingTodoBoardOrder(dragged.id), isNull);

      await repo.moveOnBoard(rehomedByDelete.id, progress, 1);
      // Re-arm only this row to model a migrated card in a column the user then
      // explicitly deletes through the destination picker.
      await db.customStatement(
        'INSERT INTO settings(key,value) VALUES(?,?)',
        <Object?>['todo_kanban_backfill:${rehomedByDelete.id}', '1'],
      );
      await repo.deleteColumn(progress, done);

      expect((await rowOf(rehomedByDelete.id)).columnId, done);
      expect(await db.pendingTodoBoardOrder(rehomedByDelete.id), isNull);
    },
  );

  test(
    'deleting a non-empty column moves cards transactionally, never todos',
    () async {
      final TodoRow a = await repo.add('a');
      final TodoRow b = await repo.add('b');
      final TodoRow retired = await repo.add('retired');
      final List<TodoColumnRow> columns = await repo.listColumns();
      final String progress = columns[1].id;
      final String done = columns[2].id;
      await repo.moveOnBoard(a.id, progress, 0);
      await repo.moveOnBoard(b.id, progress, 1);
      await repo.moveOnBoard(retired.id, progress, 2);
      await repo.softDelete(retired.id);

      await repo.deleteColumn(progress, done);

      expect(
        (await repo.listColumns()).map((c) => c.id),
        isNot(contains(progress)),
      );
      expect((await rowOf(a.id)).columnId, done);
      expect((await rowOf(b.id)).columnId, done);
      expect((await rowOf(retired.id)).columnId, done);
      expect((await rowOf(a.id)).deletedAt, isNull);
      expect((await rowOf(b.id)).deletedAt, isNull);
      expect((await rowOf(retired.id)).deletedAt, isNotNull);
      expect((await repo.listTodos()).length, 2);
    },
  );

  test(
    'column order is mutable and the last column cannot be deleted',
    () async {
      List<TodoColumnRow> columns = await repo.ensureColumns();
      await repo.reorderColumn(columns.last.id, 0);
      columns = await repo.listColumns();
      expect(columns.first.name, 'Done');

      await repo.deleteColumn(columns[2].id, columns[0].id);
      await repo.deleteColumn(columns[1].id, columns[0].id);
      await expectLater(
        repo.deleteColumn(columns[0].id, columns[0].id),
        throwsStateError,
      );
    },
  );

  test(
    'checking moves to the last live column and unchecking leaves placement',
    () async {
      final TodoRow existingDone = await repo.add('already at the end');
      final TodoRow todo = await repo.add('finish me');
      final List<TodoColumnRow> columns = await repo.listColumns();
      final String progress = columns[1].id;
      final String done = columns[2].id;
      await repo.moveOnBoard(existingDone.id, done, 0);
      await repo.moveOnBoard(todo.id, progress, 0);
      await repo.toggle(existingDone.id);
      expect((await rowOf(existingDone.id)).boardOrder, 0);
      await db.customStatement(
        'INSERT INTO settings(key,value) VALUES(?,?)',
        <Object?>['todo_kanban_backfill:${todo.id}', '1'],
      );

      await repo.toggle(todo.id);

      TodoRow checked = await rowOf(todo.id);
      expect(checked.doneAt, isNotNull);
      expect(checked.columnId, done);
      expect(checked.boardOrder, 1, reason: 'completion appends at lane end');
      expect(await db.pendingTodoBoardOrder(todo.id), isNull);

      await repo.toggle(todo.id);
      checked = await rowOf(todo.id);
      expect(checked.doneAt, isNull);
      expect(checked.columnId, done);
      expect(checked.boardOrder, 1, reason: 'unchecking never moves the card');
    },
  );

  test(
    'bulk board move appends in source order and spends every marker',
    () async {
      final TodoRow a = await repo.add('a');
      final TodoRow b = await repo.add('b');
      final TodoRow c = await repo.add('c');
      final TodoRow anchor = await repo.add('anchor');
      final String progress = (await repo.listColumns())[1].id;
      await repo.moveOnBoard(anchor.id, progress, 0);
      await db.customStatement(
        'INSERT INTO settings(key,value) VALUES(?,?),(?,?)',
        <Object?>[
          'todo_kanban_backfill:${a.id}',
          '0',
          'todo_kanban_backfill:${c.id}',
          '2',
        ],
      );

      await repo.moveManyOnBoard(<String>[a.id, c.id], progress);

      final List<TodoRow> target =
          (await repo.listTodos())
              .where((row) => row.columnId == progress)
              .toList()
            ..sort((x, y) => x.boardOrder.compareTo(y.boardOrder));
      expect(target.map((row) => row.id), <String>[anchor.id, a.id, c.id]);
      expect(target.map((row) => row.boardOrder), <int>[0, 1, 2]);
      expect((await rowOf(b.id)).boardOrder, 0, reason: 'source is compacted');
      expect(await db.pendingTodoBoardOrder(a.id), isNull);
      expect(await db.pendingTodoBoardOrder(c.id), isNull);
    },
  );

  test(
    'a stale column push acknowledgement cannot clean a newer edit',
    () async {
      final TodoColumnRow column = (await repo.ensureColumns()).first;
      final String pushedAt = column.updatedAt;
      clock = clock.add(const Duration(seconds: 1));
      await repo.renameColumn(column.id, 'Next');

      await db.markTodoColumnSynced(
        column.id,
        seq: 99,
        pushedUpdatedAt: pushedAt,
      );

      final TodoColumnRow after = (await repo.listColumns()).firstWhere(
        (candidate) => candidate.id == column.id,
      );
      expect(after.name, 'Next');
      expect(after.syncDirty, isTrue);
      expect(after.syncedSeq, isNull);
    },
  );

  test(
    'moveOnBoard dirties only the moved card and cards whose order shifts',
    () async {
      final TodoRow a = await repo.add('a');
      final TodoRow b = await repo.add('b');
      final TodoRow c = await repo.add('c');
      final TodoRow d = await repo.add('d');
      for (final TodoRow row in <TodoRow>[a, b, c, d]) {
        await db.markTodoSynced(row.id, seq: 1, pushedUpdatedAt: row.updatedAt);
      }
      await db.applyRemoteTodo(
        id: d.id,
        text: 'd changed concurrently',
        createdAt: d.createdAt,
        updatedAt: '2026-09-27T12:00:01.000Z',
        columnId: d.columnId,
        boardOrder: d.boardOrder,
        seq: 2,
      );

      clock = clock.add(const Duration(minutes: 1));
      await repo.moveOnBoard(c.id, defaultTodoColumnId, 1);

      expect((await rowOf(a.id)).syncDirty, isFalse);
      expect((await rowOf(d.id)).syncDirty, isFalse);
      expect((await rowOf(d.id)).body, 'd changed concurrently');
      expect((await rowOf(b.id)).syncDirty, isTrue, reason: 'b shifted right');
      expect((await rowOf(c.id)).syncDirty, isTrue, reason: 'c moved');
    },
  );

  test(
    'ensureColumns preserves unresolved references and deleted row stamps',
    () async {
      await repo.ensureColumns();
      await db.applyRemoteTodo(
        id: 'future-live',
        text: 'wait for its lane',
        createdAt: '2026-09-27T10:00:00.000Z',
        updatedAt: '2026-09-27T10:00:00.000Z',
        columnId: 'peer-column-not-pulled-yet',
        seq: 3,
      );
      await db.applyRemoteTodo(
        id: 'future-deleted',
        text: 'retired elsewhere',
        createdAt: '2026-09-27T10:00:00.000Z',
        updatedAt: '2026-09-27T11:00:00.000Z',
        deletedAt: '2026-09-27T11:00:00.000Z',
        columnId: 'peer-column-not-pulled-yet',
        seq: 4,
      );

      await repo.ensureColumns();

      for (final String id in <String>['future-live', 'future-deleted']) {
        final TodoRow row = (await db.getTodoRow(id))!;
        expect(row.columnId, 'peer-column-not-pulled-yet');
        expect(row.syncDirty, isFalse);
      }
      expect(
        (await db.getTodoRow('future-deleted'))!.updatedAt,
        '2026-09-27T11:00:00.000Z',
      );
    },
  );

  test(
    'column counts match rows deleteColumn will move, not UI fallbacks',
    () async {
      final List<TodoColumnRow> columns = await repo.ensureColumns();
      final TodoRow actual = await repo.add('actual');
      final TodoRow deleted = await repo.add('deleted actual');
      await repo.softDelete(deleted.id);
      await db.applyRemoteTodo(
        id: 'unresolved',
        text: 'shown in fallback only',
        createdAt: '2026-09-27T10:00:00.000Z',
        updatedAt: '2026-09-27T10:00:00.000Z',
        columnId: 'future-column',
        seq: 5,
      );

      expect(await repo.countTodosInColumn(columns.first.id), 2);
      await repo.deleteColumn(columns.first.id, columns[1].id);
      expect((await rowOf(actual.id)).columnId, columns[1].id);
      expect((await rowOf(deleted.id)).columnId, columns[1].id);
      expect((await db.getTodoRow('unresolved'))!.columnId, 'future-column');
    },
  );

  test('rename and delete reject non-live source columns', () async {
    final List<TodoColumnRow> columns = await repo.ensureColumns();
    final TodoColumnRow retired = columns.last;
    await repo.deleteColumn(retired.id, columns.first.id);

    await expectLater(repo.renameColumn(retired.id, 'Ghost'), throwsStateError);
    await expectLater(
      repo.deleteColumn(retired.id, columns.first.id),
      throwsStateError,
    );
    expect((await db.getTodoColumnRow(retired.id))!.name, retired.name);
  });
}
