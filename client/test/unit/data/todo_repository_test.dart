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
}
