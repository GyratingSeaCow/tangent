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
    DateTime? recordedOn,
  }) =>
      captureVoiceTodos(
        db: db,
        dumpId: id,
        transcript: text,
        // The dump row's created_at; a fixed day so the tests never depend
        // on when they run.
        recordedOn: recordedOn ?? DateTime(2026, 9, 27, 14, 3),
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
  group('due dates (v1.26.0)', () {
    test('a leading date phrase puts due_date on EVERY captured row',
        () async {
      final List<TodoRow> created = await arrive(
        text: 'add to my to do list for September 30th buy milk and call Dana',
        recordedOn: DateTime(2026, 9, 27, 14, 3),
      );

      expect(created.map((r) => r.body), ['buy milk', 'call Dana']);
      expect(created.map((r) => r.dueDate), ['2026-09-30', '2026-09-30']);
      // ...and it is what the database holds, not just the returned rows.
      expect(
        (await repo.todosFromSource(dumpId)).map((r) => r.dueDate),
        ['2026-09-30', '2026-09-30'],
      );
    });

    test('fixture 1: "for September 30th to go to the store" recorded 09-27',
        () async {
      final List<TodoRow> created = await arrive(
        text: 'Add to my to-do list for September 30th to go to the store.',
        recordedOn: DateTime(2026, 9, 27, 14, 3),
      );
      expect(created.single.body, 'go to the store');
      expect(created.single.dueDate, '2026-09-30');
      expect(created.single.source, 'voice');
    });

    test('a transcript with no date leaves due_date null', () async {
      final List<TodoRow> created = await arrive();
      expect(created.length, 2);
      for (final TodoRow row in created) {
        expect(row.dueDate, isNull);
      }
    });

    test('recordedOn comes from the dump row, not the clock (D2)', () async {
      // The repository clock says Sep 27 but the dump was recorded Oct 5:
      // "September 30th" must roll to next year.
      clock = DateTime.utc(2026, 9, 27, 12);
      final List<TodoRow> created = await arrive(
        text: 'Add to my to-do list for September 30th to go to the store.',
        recordedOn: DateTime(2026, 10, 5, 9),
      );
      expect(created.single.dueDate, '2027-09-30');
    });

    test('a UTC created_at is read as the local recording day', () async {
      final DateTime utcStamp = DateTime.utc(2026, 9, 30, 12);
      final List<TodoRow> created = await arrive(
        text: 'add to my to do list for September 30th pay rent',
        recordedOn: utcStamp,
      );
      // Noon UTC is Sep 30 in every zone from UTC-12 to UTC+11.
      expect(created.single.dueDate, '2026-09-30');
    });
  });

  group('relative + per-item dates (v1.27.0)', () {
    // 2026-09-27 is a Sunday.
    test('a per-item date beats the sentence date; others inherit it (R2)',
        () async {
      final List<TodoRow> created = await arrive(
        text: 'Add to my to-do list for Friday, buy milk and call mom on Sunday.',
        recordedOn: DateTime(2026, 9, 27, 14, 3),
      );
      expect(created.map((r) => r.body), ['buy milk', 'call mom']);
      expect(created.map((r) => r.dueDate), ['2026-10-02', '2026-10-04']);
      expect(
        (await repo.todosFromSource(dumpId)).map((r) => r.dueDate),
        ['2026-10-02', '2026-10-04'],
      );
    });

    test('per-item dates with NO sentence date leave the rest undated',
        () async {
      // The device-proof sentence from the spec.
      final List<TodoRow> created = await arrive(
        text: 'Add to my to-do list, call the dentist on Friday and pay the '
            'water bill tomorrow',
        recordedOn: DateTime(2026, 9, 27, 14, 3),
      );
      expect(created.map((r) => r.body), ['call the dentist', 'pay the water bill']);
      expect(created.map((r) => r.dueDate), ['2026-10-02', '2026-09-28']);

      final List<TodoRow> more = await arrive(
        id: 'dump-2',
        text: 'add to my to do list buy nails and call Dana tomorrow',
        recordedOn: DateTime(2026, 9, 27, 14, 3),
      );
      expect(more.map((r) => r.dueDate), [null, '2026-09-28']);
    });

    test('a relative sentence date resolves against the dump day, not the clock',
        () async {
      clock = DateTime.utc(2026, 9, 27, 12);
      final List<TodoRow> created = await arrive(
        text: 'Remind me to take the bins out tomorrow.',
        recordedOn: DateTime(2026, 10, 5, 9),
      );
      expect(created.single.body, 'take the bins out');
      expect(created.single.dueDate, '2026-10-06');
    });
  });
}
