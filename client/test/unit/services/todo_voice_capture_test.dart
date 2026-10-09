// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/services/todo_voice_capture.dart';
import 'package:tangent/services/todo_voice_parser.dart';

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

  test(
      'voice-created timed todo requests reminder permissions once at capture',
      () async {
    int permissionRequests = 0;
    Future<List<TodoRow>> capture(String id, String text) => captureVoiceTodos(
          db: db,
          dumpId: id,
          transcript: text,
          recordedOn: DateTime(2026, 9, 27, 14, 3),
          repository: repo,
          onTimedTodosCreated: () async => permissionRequests++,
        );

    final List<TodoRow> created = await capture(
      dumpId,
      'add to my to do list call mom tomorrow at 3 pm',
    );
    expect(created.single.dueDate, '2026-09-28');
    expect(created.single.dueTime, '15:00');
    expect(permissionRequests, 1);

    await capture(dumpId, 'add to my to do list call mom tomorrow at 3 pm');
    await capture('dump-untimed', 'add to my to do list buy milk');
    expect(
      permissionRequests,
      1,
      reason: 'idempotent replay and untimed voice capture never re-prompt',
    );
  });

  test('the SAME transcript arriving twice creates nothing new', () async {
    await arrive();
    clock = clock.add(const Duration(minutes: 5));

    final List<TodoRow> second = await arrive();

    expect(second, isEmpty);
    expect((await repo.todosFromSource(dumpId)).length, 2);
  });

  group('re-transcription guard (v1.28.0)', () {
    test(
        'a re-transcribe producing one changed item adds it, keeps the '
        'unchanged one (same id) and leaves the stale one alone', () async {
      final List<TodoRow> first = await arrive();
      final String keptId =
          first.singleWhere((r) => r.body == 'pick up thermal paste').id;
      clock = clock.add(const Duration(minutes: 5));

      final List<TodoRow> second = await arrive(
        text: 'add to my to do list pick up thermal paste '
            'and email the Zionsville customer back about the board',
      );

      expect(
        second.map((r) => r.body),
        ['email the Zionsville customer back about the board'],
      );
      final List<TodoRow> rows = await repo.todosFromSource(dumpId);
      expect(rows.map((r) => r.body), [
        'pick up thermal paste',
        'email the Zionsville customer back',
        'email the Zionsville customer back about the board',
      ]);
      expect(rows.first.id, keptId, reason: 'same text keeps its id');
      expect(
        rows.every((r) => r.deletedAt == null),
        isTrue,
        reason: 'the stale item is left alone, never deleted',
      );
    });

    test('a user-edited row survives a re-transcribe', () async {
      final List<TodoRow> first = await arrive();
      final String editedId =
          first.singleWhere((r) => r.body == 'pick up thermal paste').id;
      await repo.editText(editedId, 'pick up TWO tubes of thermal paste');

      await arrive(text: 'add to my to do list email the Zionsville customer');

      final TodoRow edited = (await db.getTodoRow(editedId))!;
      expect(edited.body, 'pick up TWO tubes of thermal paste');
      expect(edited.deletedAt, isNull);
    });

    test('identical result from different wording is the same capture',
        () async {
      final List<TodoRow> first = await arrive(
        text: 'add to my to do list for September 30th pick up thermal '
            'paste and email the Zionsville customer back',
      );
      final String fingerprint = first.first.captureFingerprint!;
      // The user clears the date on one item. A same-result re-arrival is
      // the SAME capture and must not put the date back; only a genuinely
      // different parse may reconcile.
      await repo.setDueDate(first.first.id, null);
      clock = clock.add(const Duration(minutes: 5));

      final List<TodoRow> second = await arrive(
        text: 'the customer board is toast okay add to my to do list '
            'for September 30th pick up thermal paste and email the '
            'Zionsville customer back',
      );

      expect(second, isEmpty);
      final List<TodoRow> rows = await repo.todosFromSource(dumpId);
      expect(rows.length, 2);
      expect(rows.first.dueDate, isNull, reason: 'no reconcile happened');
      expect(
        rows.every((r) => r.captureFingerprint == fingerprint),
        isTrue,
        reason: 'the fingerprint is over the result, not the wording',
      );
    });

    test('the fingerprint is over the parsed result, not the transcript',
        () async {
      final VoiceTodoParse a = TodoVoiceParser.parseWithDate(
        transcript,
        recordedOn: DateTime(2026, 9, 27),
      );
      final VoiceTodoParse b = TodoVoiceParser.parseWithDate(
        'okay so add to my to do list pick up thermal paste and email the '
        'Zionsville customer back',
        recordedOn: DateTime(2026, 9, 27),
      );
      expect(a.entries, b.entries);
      expect(captureFingerprintOf(a.entries), captureFingerprintOf(b.entries));
      expect(
        captureFingerprintOf(a.entries),
        isNot(
          captureFingerprintOf(<VoiceTodoItem>[
            const VoiceTodoItem('pick up thermal paste', dueDate: '2026-09-30'),
            const VoiceTodoItem('email the Zionsville customer back'),
          ]),
        ),
        reason: 'a date is part of the result',
      );
    });

    test('re-transcribe after Undo resurrects nothing', () async {
      await arrive();
      expect(await repo.softDeleteFromSource(dumpId), 2);

      final List<TodoRow> second = await arrive(
        text: 'add to my to do list pick up thermal paste and call Sam',
      );

      expect(second.map((r) => r.body), ['call Sam']);
      final List<TodoRow> rows = await repo.todosFromSource(dumpId);
      expect(
        rows.where((r) => r.body == 'pick up thermal paste').single.deletedAt,
        isNotNull,
        reason: 'the undone item stays deleted and is not re-created',
      );
      expect(rows.where((r) => r.body == 'pick up thermal paste').length, 1);
      expect(
        rows.where((r) => r.deletedAt == null).map((r) => r.body),
        ['call Sam'],
      );
    });

    test('a re-transcribe that adds a date sets due_date and keeps the id',
        () async {
      final List<TodoRow> first = await arrive();
      final String id =
          first.singleWhere((r) => r.body == 'pick up thermal paste').id;
      expect(first.every((r) => r.dueDate == null), isTrue);

      final List<TodoRow> second = await arrive(
        text: 'add to my to do list for September 30th pick up thermal '
            'paste and email the Zionsville customer back',
      );

      expect(second, isEmpty, reason: 'same texts, nothing new');
      final TodoRow dated = (await db.getTodoRow(id))!;
      expect(dated.dueDate, '2026-09-30');
      expect(dated.syncDirty, isTrue, reason: 'the date must travel');
    });

    test('a re-transcribe never overwrites a date the row already has',
        () async {
      await arrive(
        text: 'add to my to do list for September 30th pick up thermal paste',
      );
      final String id = (await repo.todosFromSource(dumpId)).single.id;
      await repo.setDueDate(id, '2026-10-05');

      await arrive(
        text: 'add to my to do list for October 1st pick up thermal paste',
      );

      expect((await db.getTodoRow(id))!.dueDate, '2026-10-05');
    });

    test('the same transcript arriving after a re-transcribe is a no-op',
        () async {
      await arrive();
      const String changed =
          'add to my to do list pick up thermal paste and call Sam';
      await arrive(text: changed);
      final List<TodoRow> settled = await repo.todosFromSource(dumpId);

      expect(await arrive(text: changed), isEmpty);
      expect(await repo.todosFromSource(dumpId), settled);
    });

    test('capture_fingerprint is stamped on the rows and stays local',
        () async {
      final List<TodoRow> created = await arrive();
      final String expected = captureFingerprintOf(<VoiceTodoItem>[
        const VoiceTodoItem('pick up thermal paste'),
        const VoiceTodoItem('email the Zionsville customer back'),
      ]);
      expect(created.map((r) => r.captureFingerprint), [expected, expected]);
      expect((await repo.add('by hand')).captureFingerprint, isNull);
    });
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

  test('manual-only provenance does not suppress later voice capture',
      () async {
    final TodoRow manual = await repo.add('typed by hand', sourceRef: dumpId);

    expect(manual.source, 'manual');
    expect(manual.sourceRef, dumpId);
    expect(await repo.hasTodosFromSource(dumpId), isFalse);
    expect((await arrive()).length, 2, reason: 'voice detection still fires');
    expect((await db.getTodoRow(manual.id))!.deletedAt, isNull);
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
