// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/services/due_digest.dart';
import 'package:tangent/services/due_reminder_scheduler.dart';

import '../../support/fake_due_reminder_port.dart';

void main() {
  TodoRow todo(String body, {String? due, bool done = false}) => TodoRow(
        id: 'id-$body',
        body: body,
        doneAt: done ? '2026-09-27T10:00:00Z' : null,
        dueDate: due,
        source: 'manual',
        sourceRef: null,
        createdAt: '2026-09-01',
        updatedAt: '2026-09-01',
        deletedAt: null,
        syncDirty: true,
        syncedSeq: null,
        folderId: null,
      );

  group('nextFireTime', () {
    const int seven = 7 * 60;

    test('06:59 → today 07:00', () {
      expect(
        DueReminderScheduler.nextFireTime(DateTime(2026, 9, 27, 6, 59), seven),
        DateTime(2026, 9, 27, 7),
      );
    });

    test('exactly 07:00 → tomorrow (strictly after)', () {
      expect(
        DueReminderScheduler.nextFireTime(DateTime(2026, 9, 27, 7), seven),
        DateTime(2026, 9, 28, 7),
      );
    });

    test('07:01 → tomorrow 07:00', () {
      expect(
        DueReminderScheduler.nextFireTime(DateTime(2026, 9, 27, 7, 1), seven),
        DateTime(2026, 9, 28, 7),
      );
    });

    test('rolls over month end and keeps minutes', () {
      expect(
        DueReminderScheduler.nextFireTime(
          DateTime(2026, 9, 30, 23, 0),
          21 * 60 + 45,
        ),
        DateTime(2026, 10, 1, 21, 45),
      );
    });
  });

  group('minute-of-day round-trips through SettingsStore', () {
    test('default is 420 (07:00) and reminders are off', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      expect(store.remindersEnabled, isFalse);
      expect(store.reminderMinuteOfDay, 420);
    });

    test('set then reload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      await store.setReminderMinuteOfDay(8 * 60 + 30);
      await store.setRemindersEnabled(true);
      final SettingsStore again = await SettingsStore.load();
      expect(again.reminderMinuteOfDay, 510);
      expect(again.remindersEnabled, isTrue);
    });

    test('out-of-range value is clamped to a day', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'reminder_minute_of_day': 99999,
      });
      final SettingsStore store = await SettingsStore.load();
      expect(store.reminderMinuteOfDay, 24 * 60 - 1);
      await store.setReminderMinuteOfDay(-5);
      expect(store.reminderMinuteOfDay, 0);
    });
  });

  group('DueReminderScheduler', () {
    late FakeDueReminderPort port;
    late List<TodoRow> todos;
    late DueReminderScheduler scheduler;
    final DateTime now = DateTime(2026, 9, 27, 6, 30);

    setUp(() {
      port = FakeDueReminderPort();
      todos = <TodoRow>[];
      scheduler = DueReminderScheduler(
        port: port,
        loadTodos: () async => todos,
        now: () => now,
      );
    });

    test('scheduleNext arms the next 07:00 with the predicted digest', () async {
      todos = <TodoRow>[todo('call the dentist', due: '2026-09-27')];
      final DateTime at = await scheduler.scheduleNext(minuteOfDay: 420);
      expect(at, DateTime(2026, 9, 27, 7));
      expect(port.scheduledAt, <DateTime>[at]);
      expect(port.scheduledDigests.single?.body, 'call the dentist');
      expect(port.scheduledExact, <bool>[true]);
    });

    test('falls back to inexact when exact alarms are not permitted', () async {
      port.exact = false;
      await scheduler.scheduleNext(minuteOfDay: 420);
      expect(port.scheduledExact, <bool>[false]);
    });

    test('nothing due → schedule carries no digest, task still armed', () async {
      await scheduler.scheduleNext(minuteOfDay: 420);
      expect(port.scheduledAt, hasLength(1));
      expect(port.scheduledDigests, <DueDigest?>[null]);
    });

    test('cancel goes straight to the port', () async {
      await scheduler.cancel();
      expect(port.cancels, 1);
    });

    test('runDailyTask posts the fire-time digest and re-arms tomorrow',
        () async {
      todos = <TodoRow>[
        todo('call the dentist', due: '2026-09-27'),
        todo('renew passport', due: '2026-09-20'),
      ];
      final DateTime fire = DateTime(2026, 9, 27, 7);
      final DueDigest? d =
          await scheduler.runDailyTask(minuteOfDay: 420, now: fire);
      expect(d!.body, 'call the dentist \u00B7 1 overdue');
      expect(port.posted.single.body, d.body);
      expect(port.withdraws, 0);
      expect(port.scheduledAt, <DateTime>[DateTime(2026, 9, 28, 7)]);
    });

    test('runDailyTask with an empty digest posts NOTHING and withdraws',
        () async {
      todos = <TodoRow>[todo('done one', due: '2026-09-27', done: true)];
      final DueDigest? d = await scheduler.runDailyTask(
        minuteOfDay: 420,
        now: DateTime(2026, 9, 27, 7),
      );
      expect(d, isNull);
      expect(port.posted, isEmpty);
      expect(port.withdraws, 1);
      expect(port.scheduledAt, <DateTime>[DateTime(2026, 9, 28, 7)]);
    });
  });
}
