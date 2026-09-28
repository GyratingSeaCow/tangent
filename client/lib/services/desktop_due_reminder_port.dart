// SPDX-License-Identifier: AGPL-3.0-or-later
/// The desktop (Linux + Windows) [DueReminderPort] (spec 2026-09-27
/// Half A, K1): an in-process [Timer] to the fire time plus one system
/// notification through `local_notifier`.
///
/// Desktop has no alarm/worker split, so the port never shows the digest
/// the scheduler PREDICTED: at fire time it asks [loadDigest] for the list
/// AS IT IS NOW, posts (or skips when nothing is due), records the day and
/// re-arms for the next occurrence. A `Timer` that slept through its
/// deadline fires on wake, which counts as "on time" when the day matches.
///
/// Every `local_notifier` call sits behind [DesktopNotifier] so the port is
/// unit-tested with a fake and no test ever touches the plugin.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import '../data/settings_store.dart';
import 'due_digest.dart';
import 'due_reminder_scheduler.dart';

/// Builds the digest from the live database for "now"; null = nothing due.
typedef DigestLoader = Future<DueDigest?> Function();

/// Creates a one-shot timer; injected so tests drive time themselves.
typedef TimerFactory = Timer Function(Duration delay, void Function() fire);

/// Everything the port needs from a desktop notification backend.
abstract class DesktopNotifier {
  /// One-time backend setup (Windows needs a registered app name).
  Future<void> setup();

  /// Shows a notification, replacing the previous one.
  Future<void> show({
    required String title,
    required String body,
    required void Function() onClick,
  });

  /// Closes the notification shown last, if any.
  Future<void> closeLast();
}

/// The real backend.
class LocalNotifierDesktopNotifier implements DesktopNotifier {
  LocalNotifierDesktopNotifier({required this.appName});

  final String appName;
  LocalNotification? _last;

  @override
  Future<void> setup() =>
      localNotifier.setup(appName: appName, shortcutPolicy: ShortcutPolicy.requireCreate);

  @override
  Future<void> show({
    required String title,
    required String body,
    required void Function() onClick,
  }) async {
    await closeLast();
    final LocalNotification notification =
        LocalNotification(title: title, body: body)..onClick = onClick;
    _last = notification;
    await notification.show();
  }

  @override
  Future<void> closeLast() async {
    final LocalNotification? last = _last;
    _last = null;
    if (last != null) await last.destroy();
  }
}

class DesktopDueReminderPort implements DueReminderPort {
  DesktopDueReminderPort({
    required DesktopNotifier notifier,
    required DigestLoader loadDigest,
    required Future<void> Function(String isoDay) onPosted,
    required void Function() onClick,
    DateTime Function()? now,
    TimerFactory? timerFactory,
  })  : _notifier = notifier,
        _loadDigest = loadDigest,
        _onPosted = onPosted,
        _onClick = onClick,
        _now = now ?? DateTime.now,
        _newTimer = timerFactory ?? _realTimer;

  static Timer _realTimer(Duration delay, void Function() fire) =>
      Timer(delay, fire);

  final DesktopNotifier _notifier;
  final DigestLoader _loadDigest;
  final Future<void> Function(String isoDay) _onPosted;
  final void Function() _onClick;
  final DateTime Function() _now;
  final TimerFactory _newTimer;

  Timer? _timer;

  /// The instant the armed timer will fire; null when nothing is armed.
  DateTime? get armedFor => _armedFor;
  DateTime? _armedFor;

  @override
  bool get canOpenSystemSettings => false;

  /// Desktop has no runtime notification permission.
  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> canScheduleExact() async => true;

  /// [digest] is deliberately ignored: desktop always builds live at fire
  /// time, so a to-do added or completed after arming is never misreported.
  @override
  Future<void> schedule({
    required DateTime fireAt,
    required DueDigest? digest,
    required bool exact,
  }) async {
    _timer?.cancel();
    Duration delay = fireAt.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    _armedFor = fireAt;
    _timer = _newTimer(delay, () => unawaited(_fire(fireAt)));
  }

  Future<void> _fire(DateTime fireAt) async {
    _timer = null;
    _armedFor = null;
    final DateTime at = _now();
    try {
      final DueDigest? digest = await _loadDigest();
      if (digest != null) {
        await post(digest);
        await _onPosted(isoDate(at));
      }
    } catch (error, stack) {
      _report('fire', error, stack);
    }
    // Same wall-clock time, next occurrence strictly after now — a timer
    // that slept past midnight must not re-arm into the past and fire twice.
    final int minuteOfDay = fireAt.hour * 60 + fireAt.minute;
    await schedule(
      fireAt: DueReminderScheduler.nextFireTime(at, minuteOfDay),
      digest: null,
      exact: true,
    );
  }

  @override
  Future<void> post(DueDigest digest) async {
    try {
      await _notifier.show(
        title: digest.title,
        body: digest.body,
        onClick: _onClick,
      );
    } catch (error, stack) {
      _report('post', error, stack);
    }
  }

  @override
  Future<void> withdraw() async {
    try {
      await _notifier.closeLast();
    } catch (error, stack) {
      _report('withdraw', error, stack);
    }
  }

  @override
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    _armedFor = null;
    await withdraw();
  }

  /// Nothing to open on desktop; the section hides the button.
  @override
  Future<void> openSystemSettings() async {}

  void _report(String operation, Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'tangent',
        context: ErrorDescription(
          'while trying to $operation the desktop due-date reminder',
        ),
      ),
    );
  }
}

/// `H:MM` for the "Missed 7:00 · " prefix: hour unpadded, minute padded.
String missedReminderPrefix(int minuteOfDay) {
  final int hour = minuteOfDay ~/ 60;
  final String minute = (minuteOfDay % 60).toString().padLeft(2, '0');
  return 'Missed $hour:$minute \u00B7 ';
}

/// K1 catch-up, on desktop app start. When reminders are on, the chosen
/// time has already passed today and no reminder was shown today, build
/// the digest live and post it with the `Missed H:MM · ` prefix, then
/// record the day so the same day never gets it twice. Returns what was
/// posted (null when nothing was).
Future<DueDigest?> runDesktopReminderCatchUp({
  required SettingsStore settings,
  required DueReminderPort port,
  required DigestLoader loadDigest,
  required DateTime now,
}) async {
  if (!settings.remindersEnabled) return null;
  final int minuteOfDay = now.hour * 60 + now.minute;
  if (minuteOfDay < settings.reminderMinuteOfDay) return null;
  final String today = isoDate(now);
  if (settings.lastReminderShownDay == today) return null;
  final DueDigest? digest = await loadDigest();
  if (digest == null) return null;
  final DueDigest missed = DueDigest(
    title: '${missedReminderPrefix(settings.reminderMinuteOfDay)}${digest.title}',
    body: digest.body,
    dueTodayCount: digest.dueTodayCount,
    overdueCount: digest.overdueCount,
  );
  await port.post(missed);
  await settings.setLastReminderShownDay(today);
  return missed;
}
