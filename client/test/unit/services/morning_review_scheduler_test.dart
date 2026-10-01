// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/services/due_digest.dart';
import 'package:tangent/services/morning_review_scheduler.dart';

import '../../support/fake_due_reminder_port.dart';

/// Ask-arc queued item 2: the morning-review scheduler over the shared
/// reminder-port contract — arming, fire-time truth, cancel, and the
/// desktop catch-up.
void main() {
  DumpRow dump(String id, DateTime createdAt) => DumpRow(
        id: id,
        createdAt: createdAt,
        updatedAt: createdAt,
        mode: 'brain_dump',
        durationSeconds: 30,
        title: id,
        audioPath: '/synthetic/$id.opus',
        audioSizeBytes: 1024,
        syncStatus: 'local_only',
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      );

  late FakeDueReminderPort port;
  List<DumpRow> dumps = <DumpRow>[];

  setUp(() {
    port = FakeDueReminderPort();
    dumps = <DumpRow>[];
  });

  MorningReviewScheduler scheduler({
    DateTime? now,
    Future<void> Function(String)? onPosted,
  }) =>
      MorningReviewScheduler(
        port: port,
        loadDumps: () async => dumps,
        now: () => now ?? DateTime(2026, 9, 30, 6, 30),
        onPosted: onPosted,
      );

  group('scheduleNext', () {
    test('arms the next 08:00 strictly after now, with a predicted digest',
        () async {
      dumps = <DumpRow>[dump('x', DateTime(2026, 9, 29, 14))];
      final DateTime fireAt = await scheduler()
          .scheduleNext(minuteOfDay: kDefaultMorningReviewMinuteOfDay);
      expect(fireAt, DateTime(2026, 9, 30, 8));
      expect(port.scheduledAt, <DateTime>[DateTime(2026, 9, 30, 8)]);
      expect(port.scheduledDigests.single?.title, 'Morning review');
      expect(port.scheduledDigests.single?.body, 'Yesterday: x');
    });

    test('arms with no digest when the predicted yesterday is empty',
        () async {
      await scheduler()
          .scheduleNext(minuteOfDay: kDefaultMorningReviewMinuteOfDay);
      expect(port.scheduledAt, hasLength(1));
      expect(port.scheduledDigests.single, isNull);
    });

    test('after 08:00 the prediction covers the fire day\'s yesterday',
        () async {
      // Now 09:00 on the 30th → fires tomorrow → "yesterday" is the 30th.
      dumps = <DumpRow>[
        dump('old', DateTime(2026, 9, 29, 10)),
        dump('fresh', DateTime(2026, 9, 30, 8, 30)),
      ];
      final DateTime fireAt = await scheduler(now: DateTime(2026, 9, 30, 9))
          .scheduleNext(minuteOfDay: kDefaultMorningReviewMinuteOfDay);
      expect(fireAt, DateTime(2026, 10, 1, 8));
      expect(port.scheduledDigests.single?.body, 'Yesterday: fresh');
    });
  });

  group('runDailyTask', () {
    test('posts the live review, records the day, arms tomorrow', () async {
      dumps = <DumpRow>[dump('walk notes', DateTime(2026, 9, 29, 18))];
      final List<String> postedDays = <String>[];
      final DueDigest? posted =
          await scheduler(now: DateTime(2026, 9, 30, 8), onPosted: (d) async {
        postedDays.add(d);
      },).runDailyTask(minuteOfDay: kDefaultMorningReviewMinuteOfDay);
      expect(posted?.body, 'Yesterday: walk notes');
      expect(port.posted.single.title, 'Morning review');
      expect(postedDays, <String>['2026-09-30']);
      expect(port.scheduledAt.last, DateTime(2026, 10, 1, 8));
    });

    test('withdraws instead of posting when yesterday captured nothing',
        () async {
      final DueDigest? posted = await scheduler(now: DateTime(2026, 9, 30, 8))
          .runDailyTask(minuteOfDay: kDefaultMorningReviewMinuteOfDay);
      expect(posted, isNull);
      expect(port.posted, isEmpty);
      expect(port.withdraws, 1);
      // Still arms tomorrow: an empty yesterday is not a cancelled feature.
      expect(port.scheduledAt.last, DateTime(2026, 10, 1, 8));
    });
  });

  test('cancel reaches the port once', () async {
    await scheduler().cancel();
    expect(port.cancels, 1);
  });

  group('runDesktopMorningReviewCatchUp', () {
    SettingsStore store({
      bool enabled = true,
      String shownDay = '',
      int minute = 480,
    }) =>
        SettingsStore(
          morningReviewEnabled: enabled,
          morningReviewMinuteOfDay: minute,
          lastMorningReviewShownDay: shownDay,
        );

    test('posts the missed review once, with the Missed prefix', () async {
      dumps = <DumpRow>[dump('x', DateTime(2026, 9, 29, 14))];
      final SettingsStore settings = store();
      final DueDigest? posted = await runDesktopMorningReviewCatchUp(
        settings: settings,
        port: port,
        loadDumps: () async => dumps,
        now: DateTime(2026, 9, 30, 9, 30),
      );
      expect(posted?.title, 'Missed 8:00 \u00B7 Morning review');
      expect(posted?.body, 'Yesterday: x');
      expect(port.posted, hasLength(1));
      expect(settings.lastMorningReviewShownDay, '2026-09-30');
    });

    test('nothing while off, before the time, already shown, or empty',
        () async {
      dumps = <DumpRow>[dump('x', DateTime(2026, 9, 29, 14))];
      final DateTime after = DateTime(2026, 9, 30, 9);
      expect(
        await runDesktopMorningReviewCatchUp(
          settings: store(enabled: false),
          port: port,
          loadDumps: () async => dumps,
          now: after,
        ),
        isNull,
      );
      expect(
        await runDesktopMorningReviewCatchUp(
          settings: store(),
          port: port,
          loadDumps: () async => dumps,
          now: DateTime(2026, 9, 30, 7, 59),
        ),
        isNull,
      );
      expect(
        await runDesktopMorningReviewCatchUp(
          settings: store(shownDay: '2026-09-30'),
          port: port,
          loadDumps: () async => dumps,
          now: after,
        ),
        isNull,
      );
      expect(
        await runDesktopMorningReviewCatchUp(
          settings: store(),
          port: port,
          loadDumps: () async => <DumpRow>[],
          now: after,
        ),
        isNull,
      );
      expect(port.posted, isEmpty);
    });
  });
}
