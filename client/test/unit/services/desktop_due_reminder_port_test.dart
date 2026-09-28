// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/services/desktop_due_reminder_port.dart';
import 'package:tangent/services/due_digest.dart';

import '../../support/fake_due_reminder_port.dart';

/// Records every backend call; the plugin is never touched.
class FakeDesktopNotifier implements DesktopNotifier {
  int setups = 0;
  int closes = 0;
  final List<String> shownTitles = <String>[];
  final List<String> shownBodies = <String>[];
  void Function()? lastOnClick;

  @override
  Future<void> setup() async => setups++;

  @override
  Future<void> show({
    required String title,
    required String body,
    required void Function() onClick,
  }) async {
    shownTitles.add(title);
    shownBodies.add(body);
    lastOnClick = onClick;
  }

  @override
  Future<void> closeLast() async => closes++;
}

const DueDigest live = DueDigest(
  title: 'Due today',
  body: 'call the dentist',
  dueTodayCount: 1,
  overdueCount: 0,
);

const DueDigest predicted = DueDigest(
  title: 'Due today',
  body: 'PREDICTED — must never be shown',
  dueTodayCount: 1,
  overdueCount: 0,
);

void main() {
  group('DesktopDueReminderPort', () {
    late FakeDesktopNotifier notifier;
    late List<String> recordedDays;
    late int loaderCalls;
    late int clicks;
    DueDigest? loaderResult;

    setUp(() {
      notifier = FakeDesktopNotifier();
      recordedDays = <String>[];
      loaderCalls = 0;
      clicks = 0;
      loaderResult = live;
    });

    /// Runs [body] under fakeAsync with a clock that starts at [start] and
    /// a port whose Timer + `now` both come from that clock.
    void run(DateTime start, void Function(FakeAsync async, DesktopDueReminderPort port) body) {
      fakeAsync((FakeAsync async) {
        final DesktopDueReminderPort port = DesktopDueReminderPort(
          notifier: notifier,
          loadDigest: () async {
            loaderCalls++;
            return loaderResult;
          },
          onPosted: (String day) async => recordedDays.add(day),
          onClick: () => clicks++,
          now: () => start.add(async.elapsed),
          timerFactory: (Duration d, void Function() fire) => Timer(d, fire),
        );
        body(async, port);
      });
    }

    test('permission and exact are always granted; settings not openable', () {
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        bool? granted;
        bool? exact;
        port.requestNotificationPermission().then((v) => granted = v);
        port.canScheduleExact().then((v) => exact = v);
        async.flushMicrotasks();
        expect(granted, isTrue);
        expect(exact, isTrue);
        expect(port.canOpenSystemSettings, isFalse);
      });
    });

    test('schedule → timer fires at fireAt → live loader called → post, day recorded, re-armed',
        () {
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 7),
          digest: predicted,
          exact: true,
        );
        async.flushMicrotasks();
        expect(port.armedFor, DateTime(2026, 9, 27, 7));
        async.elapse(const Duration(minutes: 29, seconds: 59));
        expect(loaderCalls, 0);
        expect(notifier.shownTitles, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(loaderCalls, 1, reason: 'the live loader must run at fire time');
        expect(notifier.shownTitles, <String>['Due today']);
        expect(notifier.shownBodies, <String>[live.body]);
        expect(notifier.shownBodies, isNot(contains(predicted.body)));
        expect(recordedDays, <String>['2026-09-27']);
        // Re-armed for tomorrow, same wall-clock minute.
        expect(port.armedFor, DateTime(2026, 9, 28, 7));
        async.elapse(const Duration(days: 1));
        expect(loaderCalls, 2);
        expect(notifier.shownTitles.length, 2);
        expect(recordedDays, <String>['2026-09-27', '2026-09-28']);
        port.cancel();
        async.flushMicrotasks();
      });
    });

    test('empty digest at fire time → no post, day NOT recorded, still re-armed',
        () {
      loaderResult = null;
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 7),
          digest: predicted,
          exact: true,
        );
        async.elapse(const Duration(minutes: 30));
        expect(loaderCalls, 1);
        expect(notifier.shownTitles, isEmpty);
        expect(recordedDays, isEmpty);
        expect(port.armedFor, DateTime(2026, 9, 28, 7));
        port.cancel();
        async.flushMicrotasks();
      });
    });

    test('cancel before fire → nothing happens, notification closed', () {
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 7),
          digest: predicted,
          exact: true,
        );
        async.elapse(const Duration(minutes: 10));
        port.cancel();
        async.flushMicrotasks();
        expect(port.armedFor, isNull);
        async.elapse(const Duration(days: 2));
        expect(loaderCalls, 0);
        expect(notifier.shownTitles, isEmpty);
        expect(recordedDays, isEmpty);
        expect(notifier.closes, 1);
      });
    });

    test('a second schedule replaces the first timer', () {
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 7),
          digest: null,
          exact: true,
        );
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 8),
          digest: null,
          exact: true,
        );
        async.elapse(const Duration(minutes: 30));
        expect(loaderCalls, 0);
        async.elapse(const Duration(hours: 1));
        expect(loaderCalls, 1);
        port.cancel();
        async.flushMicrotasks();
      });
    });

    test('post shows title/body; click runs the tap handler; withdraw closes',
        () {
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.post(live);
        async.flushMicrotasks();
        expect(notifier.shownTitles, <String>['Due today']);
        notifier.lastOnClick!();
        expect(clicks, 1);
        port.withdraw();
        async.flushMicrotasks();
        expect(notifier.closes, 1);
        port.openSystemSettings();
        async.flushMicrotasks();
      });
    });

    test('a timer that slept past its deadline fires on wake and re-arms strictly after now',
        () {
      // The clock jumps 3 hours past the deadline (suspend/resume); the
      // timer fires once and the next arm is tomorrow, not "today 07:00".
      run(DateTime(2026, 9, 27, 6, 30), (async, port) {
        port.schedule(
          fireAt: DateTime(2026, 9, 27, 7),
          digest: null,
          exact: true,
        );
        async.elapse(const Duration(hours: 3, minutes: 30));
        expect(loaderCalls, 1);
        expect(notifier.shownTitles.length, 1);
        expect(recordedDays, <String>['2026-09-27']);
        expect(port.armedFor, DateTime(2026, 9, 28, 7));
        port.cancel();
        async.flushMicrotasks();
      });
    });
  });

  group('missedReminderPrefix', () {
    test('formats H:MM', () {
      expect(missedReminderPrefix(7 * 60), 'Missed 7:00 \u00B7 ');
      expect(missedReminderPrefix(8 * 60 + 5), 'Missed 8:05 \u00B7 ');
      expect(missedReminderPrefix(0), 'Missed 0:00 \u00B7 ');
      expect(missedReminderPrefix(23 * 60 + 59), 'Missed 23:59 \u00B7 ');
    });
  });

  group('runDesktopReminderCatchUp (K1)', () {
    late FakeDueReminderPort port;
    late SettingsStore settings;
    int loaderCalls = 0;
    DueDigest? loaderResult = live;

    setUp(() {
      port = FakeDueReminderPort();
      settings = SettingsStore(remindersEnabled: true, reminderMinuteOfDay: 420);
      loaderCalls = 0;
      loaderResult = live;
    });

    Future<DueDigest?> catchUp(DateTime now) => runDesktopReminderCatchUp(
          settings: settings,
          port: port,
          loadDigest: () async {
            loaderCalls++;
            return loaderResult;
          },
          now: now,
        );

    test('enabled, 09:00 > 07:00, day unrecorded → posted with Missed prefix, day recorded',
        () async {
      final DueDigest? posted = await catchUp(DateTime(2026, 9, 27, 9));
      expect(posted, isNotNull);
      expect(port.posted.single.title, 'Missed 7:00 \u00B7 Due today');
      expect(port.posted.single.body, live.body);
      expect(settings.lastReminderShownDay, '2026-09-27');
      expect(loaderCalls, 1);
    });

    test('same day again → nothing', () async {
      await catchUp(DateTime(2026, 9, 27, 9));
      final DueDigest? again = await catchUp(DateTime(2026, 9, 27, 11));
      expect(again, isNull);
      expect(port.posted.length, 1);
      expect(loaderCalls, 1);
    });

    test('day already recorded by the on-time reminder → nothing', () async {
      settings.lastReminderShownDay = '2026-09-27';
      expect(await catchUp(DateTime(2026, 9, 27, 9)), isNull);
      expect(port.posted, isEmpty);
      expect(loaderCalls, 0);
    });

    test('06:00 (before the chosen time) → nothing', () async {
      expect(await catchUp(DateTime(2026, 9, 27, 6)), isNull);
      expect(port.posted, isEmpty);
      expect(loaderCalls, 0);
      expect(settings.lastReminderShownDay, '');
    });

    test('exactly 07:00 counts as after → posted', () async {
      expect(await catchUp(DateTime(2026, 9, 27, 7)), isNotNull);
      expect(port.posted.length, 1);
    });

    test('disabled → nothing', () async {
      settings.remindersEnabled = false;
      expect(await catchUp(DateTime(2026, 9, 27, 9)), isNull);
      expect(port.posted, isEmpty);
      expect(loaderCalls, 0);
    });

    test('nothing due → no post and the day stays unrecorded', () async {
      loaderResult = null;
      expect(await catchUp(DateTime(2026, 9, 27, 9)), isNull);
      expect(port.posted, isEmpty);
      expect(settings.lastReminderShownDay, '');
    });

    test('a new day after a recorded one → posted again', () async {
      settings.lastReminderShownDay = '2026-09-27';
      expect(await catchUp(DateTime(2026, 9, 28, 9)), isNotNull);
      expect(settings.lastReminderShownDay, '2026-09-28');
    });
  });
}
