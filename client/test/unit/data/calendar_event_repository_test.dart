// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/calendar_event_repository.dart';
import 'package:tangent/data/local_db.dart';

void main() {
  late LocalDb db;
  late CalendarEventRepository repo;
  int n = 0;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    n = 0;
    repo = CalendarEventRepository(db: db, idFactory: () => 'ev-${++n}');
  });
  tearDown(() => db.close());

  Future<CalendarEventRow> add(String title, {bool needsDate = false}) =>
      repo.add(
        title: title,
        start: '2026-10-01',
        end: '2026-10-02',
        allDay: true,
        timeZone: 'America/New_York',
        needsDate: needsDate,
        sourceRef: 'dump-1',
        captureFingerprint: 'fp',
      );

  test('add stamps timestamps, dirty, voice source, and the fingerprint',
      () async {
    final CalendarEventRow row = await add('Dentist', needsDate: true);
    expect(row.id, 'ev-1');
    expect(row.source, 'voice');
    expect(row.sourceRef, 'dump-1');
    expect(row.needsDate, isTrue);
    expect(row.syncDirty, isTrue);
    expect(row.captureFingerprint, 'fp');
    expect(row.createdAt, row.updatedAt);
    expect(row.googleEventId, isNull);
  });

  test('watchEventsFromSource shows live rows only; eventsFromSource shows all',
      () async {
    await add('A');
    await add('B');
    expect((await repo.watchEventsFromSource('dump-1').first).length, 2);
    await repo.softDelete('ev-1');
    expect(
      (await repo.watchEventsFromSource('dump-1').first).map((r) => r.title),
      ['B'],
    );
    expect(
      (await repo.eventsFromSource('dump-1')).length,
      2,
      reason: 'soft-deleted rows stay as provenance',
    );
  });

  test('softDeleteFromSource is the Undo: every live row, dirty, stamped',
      () async {
    await add('A');
    await add('B');
    expect(await repo.softDeleteFromSource('dump-1'), 2);
    for (final CalendarEventRow r in await repo.eventsFromSource('dump-1')) {
      expect(r.deletedAt, isNotNull);
      expect(r.syncDirty, isTrue);
    }
    expect(await repo.softDeleteFromSource('dump-1'), 0);
  });

  test('setCaptureFingerprint neither bumps updated_at nor dirties', () async {
    final CalendarEventRow row = await add('A');
    await db.markCalendarEventSynced(
      row.id,
      seq: 1,
      pushedUpdatedAt: row.updatedAt,
    );
    await repo.setCaptureFingerprint('dump-1', 'fp-2');
    final CalendarEventRow after = (await db.getCalendarEventRow(row.id))!;
    expect(after.captureFingerprint, 'fp-2');
    expect(after.updatedAt, row.updatedAt);
    expect(after.syncDirty, isFalse);
  });

  test('restore clears deleted_at and dirties', () async {
    final CalendarEventRow row = await add('A');
    await repo.softDelete(row.id);
    await repo.restore(row.id);
    final CalendarEventRow after = (await db.getCalendarEventRow(row.id))!;
    expect(after.deletedAt, isNull);
    expect(after.syncDirty, isTrue);
  });
}
