// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/services/todo_voice_capture.dart';

/// To Do arc Phase 2: transcript arrival -> voice todos, against real SQL.
///
/// The rule under test is the expensive one: a transcript arriving TWICE
/// (re-sync, re-transcribe, sidecar repair) must add nothing the second
/// time, and Undo must be permanent — the idempotency query counts
/// soft-deleted rows, so a later arrival cannot resurrect what the user
/// dismissed.
void main() {
  late LocalDb db;
  late TodoRepository repo;
  late DateTime clock;
  int ids = 0;

  const String dumpId = 'dump-1';
  const String transcript =
      'customer board is toast, add to my to do list pick up thermal paste '
      'and email the Zionsville customer back';

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

  Future<List<TodoRow>> arrive({
    String id = dumpId,
    String? text = transcript,
  }) =>
      captureVoiceTodos(
        db: db,
        dumpId: id,
        transcript: text,
        repository: repo,
      );

  test('transcript arrival creates voice todos with source and source_ref',
      () async {
    final List<TodoRow> created = await arrive();

    expect(created.map((r) => r.body), [
      'pick up thermal paste',
      'email the Zionsville customer back',
    ]);
    for (final TodoRow row in created) {
      expect(row.source, 'voice');
      expect(row.sourceRef, dumpId);
      expect(row.doneAt, isNull);
      expect(row.deletedAt, isNull);
      // Auto-added items still have to travel to the user's other devices.
      expect(row.syncDirty, isTrue);
    }
  });

  test('the SAME transcript arriving twice creates nothing new', () async {
    await arrive();
    clock = clock.add(const Duration(minutes: 5));

    final List<TodoRow> second = await arrive();

    expect(second, isEmpty);
    expect((await repo.todosFromSource(dumpId)).length, 2);
  });

  test('a re-transcribe with DIFFERENT text still adds nothing', () async {
    await arrive();

    final List<TodoRow> second = await arrive(
      text: 'add to my to do list something else entirely',
    );

    expect(second, isEmpty);
    expect((await repo.todosFromSource(dumpId)).map((r) => r.body), [
      'pick up thermal paste',
      'email the Zionsville customer back',
    ]);
  });

  test('after Undo a third arrival still creates nothing (no resurrection)',
      () async {
    await arrive();

    final int undone = await repo.softDeleteFromSource(dumpId);
    expect(undone, 2);
    expect(await repo.watchTodosFromSource(dumpId).first, isEmpty);

    clock = clock.add(const Duration(hours: 1));
    final List<TodoRow> third = await arrive();

    expect(third, isEmpty);
    // The rows are still there as tombstoned provenance — that IS the
    // memory that stops detection re-firing.
    expect((await repo.todosFromSource(dumpId)).length, 2);
    expect(
      (await repo.todosFromSource(dumpId)).every((r) => r.deletedAt != null),
      isTrue,
    );
    expect(await repo.watchTodosFromSource(dumpId).first, isEmpty);
  });

  test('no trigger in the transcript adds nothing and leaves no provenance',
      () async {
    expect(await arrive(text: 'just thinking out loud about the shop'), isEmpty);
    expect(await repo.todosFromSource(dumpId), isEmpty);
    // ...and a later arrival WITH a trigger is therefore still free to fire.
    expect((await arrive()).length, 2);
  });

  test('the trigger alone with nothing after it adds nothing', () async {
    expect(await arrive(text: 'okay, add to my to do list'), isEmpty);
    expect(await repo.todosFromSource(dumpId), isEmpty);
  });

  test('a null transcript is safe', () async {
    expect(await arrive(text: null), isEmpty);
    expect(await repo.todosFromSource(dumpId), isEmpty);
  });

  test('two different dumps each capture their own items', () async {
    await arrive();
    await arrive(id: 'dump-2', text: 'remind me to sweep the bench');

    expect((await repo.todosFromSource(dumpId)).length, 2);
    expect(
      (await repo.todosFromSource('dump-2')).map((r) => r.body),
      ['sweep the bench'],
    );
    // Undo on one dump leaves the other alone.
    await repo.softDeleteFromSource(dumpId);
    expect((await repo.watchTodosFromSource('dump-2').first).length, 1);
  });

  test('manual todos carry the phase 1 defaults, not voice provenance',
      () async {
    final TodoRow manual = await repo.add('typed by hand');

    expect(manual.source, 'manual');
    expect(manual.sourceRef, isNull);
    expect(await repo.hasTodosFromSource(dumpId), isFalse);
  });
}
