// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/calendar_event_repository.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/services/calendar_voice_capture.dart';

void main() {
  late LocalDb db;
  late CalendarEventRepository repo;
  int n = 0;
  final DateTime on = DateTime(2026, 9, 28, 20);

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    n = 0;
    repo = CalendarEventRepository(db: db, idFactory: () => 'ev-${++n}');
  });
  tearDown(() => db.close());

  Future<List<CalendarEventRow>> capture(
    String? transcript, {
    DumpMode mode = DumpMode.brainDump,
  }) =>
      captureVoiceEvents(
        db: db,
        dumpId: 'dump-1',
        transcript: transcript,
        recordedOn: on,
        mode: mode,
        timeZone: 'America/New_York',
        repository: repo,
      );

  const String two = 'add to my calendar dentist Thursday at 2 and also '
      'put this on my calendar oil change Saturday';

  test('first capture inserts every event with the fingerprint', () async {
    final List<CalendarEventRow> rows = await capture(two);
    expect(rows.map((r) => r.title), ['Dentist', 'Oil change']);
    expect(rows[0].start, '2026-10-01T14:00:00');
    expect(rows[0].timeZone, 'America/New_York');
    expect(rows[0].captureFingerprint, isNotNull);
    expect(rows[0].captureFingerprint, rows[1].captureFingerprint);
  });

  test('same transcript again → no new rows', () async {
    await capture(two);
    expect(await capture(two), isEmpty);
    expect((await repo.eventsFromSource('dump-1')).length, 2);
  });

  test('re-transcription adds only the new event, keeps existing ids',
      () async {
    await capture(two);
    final List<CalendarEventRow> added = await capture(
      '$two and add to my calendar team lunch Friday at noon',
    );
    expect(added.map((r) => r.title), ['Team lunch']);
    expect(added.single.start, '2026-10-02T12:00:00');
    final List<CalendarEventRow> all = await repo.eventsFromSource('dump-1');
    expect(all.map((r) => r.id), ['ev-1', 'ev-2', 'ev-3']);
  });

  test('after Undo a re-run does NOT resurrect (Undo is permanent)', () async {
    await capture(two);
    await repo.softDeleteFromSource('dump-1');
    expect(
      await capture('$two.'),
      isEmpty,
      reason: 'new fingerprint, same events',
    );
    final List<CalendarEventRow> all = await repo.eventsFromSource('dump-1');
    expect(all.length, 2);
    expect(all.every((r) => r.deletedAt != null), isTrue);
  });

  test('meeting + no date → nothing inserted; meeting + date → inserted',
      () async {
    expect(
      await capture('put that on the calendar', mode: DumpMode.meeting),
      isEmpty,
    );
    final List<CalendarEventRow> rows = await capture(
      'add to my calendar sprint review Friday at 10',
      mode: DumpMode.meeting,
    );
    expect(rows.single.title, 'Sprint review');
  });

  test('null / trigger-less transcript → nothing', () async {
    expect(await capture(null), isEmpty);
    expect(await capture('remind me to call mom'), isEmpty);
    expect(await repo.eventsFromSource('dump-1'), isEmpty);
  });

  test('fingerprint is over the parsed result, not the raw text', () async {
    await capture(two);
    // Whitespace / punctuation noise yields the same events → same capture.
    expect(await capture('  $two  '), isEmpty);
  });
}
