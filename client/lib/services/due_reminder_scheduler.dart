// SPDX-License-Identifier: AGPL-3.0-or-later
/// Daily due-date reminder scheduling (spec 2026-09-27, Half B), Android.
///
/// Two layers, deliberately: [DueReminderScheduler] owns every DECISION
/// (when the next reminder fires, what it says, whether to post at all) and
/// is fully unit-tested against a fake [DueReminderPort]; the port owns the
/// plugin calls and nothing else, because under `flutter test` no plugin has
/// a platform implementation.
///
/// Mechanics on device: ONE exact `zonedSchedule` alarm at the next
/// `hh:mm` strictly after now (falling back to inexact when the OS refuses
/// exact alarms) carries a digest PREDICTED from the current list, so the
/// notice lands on the minute. A `workmanager` one-off task registered for
/// the same instant re-reads the database at fire time, replaces the notice
/// with the real digest (or withdraws it when nothing is due), and
/// schedules the following day.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart';
import '../data/todo_repository.dart';
import 'due_digest.dart';

/// Unique name of the background task that posts the digest at fire time.
/// Handled by the same WorkManager dispatcher as document sync.
const String kDueReminderTaskName = 'tangent.dueReminder.daily';

/// Notification channel for the reminder (importance default: it is meant
/// to be seen, unlike the low-importance transcription progress notice).
const String kDueReminderChannelId = 'due_reminders';
const String kDueReminderChannelName = 'Due-date reminders';

/// Tap payload; `main.dart` routes it to the To Do screen.
const String kDueReminderPayload = 'todo';

/// Fixed id: the shade shows one reminder that is replaced, never a stack.
const int kDueReminderNotificationId = 1101;

/// Default reminder time: 07:00 local (N1), stored as minute-of-day.
const int kDefaultReminderMinuteOfDay = 7 * 60;

/// Everything the scheduler needs from the platform, and nothing more.
abstract class DueReminderPort {
  /// Asks for POST_NOTIFICATIONS; true when granted.
  Future<bool> requestNotificationPermission();

  /// Android 12+: whether exact alarms are allowed for this app.
  Future<bool> canScheduleExact();

  /// Arms the alarm for [fireAt] and the background task for the same
  /// instant. [digest] is the PREDICTED content to show at that moment;
  /// null means arm the task only (nothing is expected to be due) — the
  /// task decides for real when it runs. Replaces any earlier schedule.
  Future<void> schedule({
    required DateTime fireAt,
    required DueDigest? digest,
    required bool exact,
  });

  /// Posts [digest] now (the fire-time correction), replacing the pending
  /// or already-shown reminder.
  Future<void> post(DueDigest digest);

  /// Withdraws the shown/scheduled reminder without touching the schedule.
  Future<void> withdraw();

  /// Cancels the alarm, the shown reminder and the background task.
  Future<void> cancel();

  /// Opens the system notification settings for the app.
  Future<void> openSystemSettings();
}

/// Decisions only; see the library doc.
class DueReminderScheduler {
  DueReminderScheduler({
    required DueReminderPort port,
    required Future<List<TodoRow>> Function() loadTodos,
    DateTime Function()? now,
  })  : _port = port,
        _loadTodos = loadTodos,
        _now = now ?? DateTime.now;

  final DueReminderPort _port;
  final Future<List<TodoRow>> Function() _loadTodos;
  final DateTime Function() _now;

  /// The next occurrence of [minuteOfDay] STRICTLY after [now], in local
  /// time. At exactly 07:00 the answer is tomorrow 07:00, never "now" —
  /// an alarm set for the current instant is already late and either
  /// fires immediately (a reminder the user did not ask for at that
  /// moment) or, on some OEMs, never.
  static DateTime nextFireTime(DateTime now, int minuteOfDay) {
    final int hour = minuteOfDay ~/ 60;
    final int minute = minuteOfDay % 60;
    DateTime candidate =
        DateTime(now.year, now.month, now.day, hour, minute);
    if (!candidate.isAfter(now)) {
      candidate = DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
    return candidate;
  }

  Future<bool> requestPermission() => _port.requestNotificationPermission();

  Future<bool> exactAllowed() => _port.canScheduleExact();

  Future<void> openSystemSettings() => _port.openSystemSettings();

  /// Arms the next reminder. Returns the instant it will fire.
  Future<DateTime> scheduleNext({
    required int minuteOfDay,
    DateTime? now,
  }) async {
    final DateTime at = now ?? _now();
    final DateTime fireAt = nextFireTime(at, minuteOfDay);
    final List<TodoRow> todos = await _loadTodos();
    final DueDigest? predicted = buildDueDigest(todos, fireAt);
    final bool exact = await _port.canScheduleExact();
    await _port.schedule(fireAt: fireAt, digest: predicted, exact: exact);
    return fireAt;
  }

  /// Toggle-off: nothing pending, nothing shown, nothing queued.
  Future<void> cancel() => _port.cancel();

  /// The background task's body, at fire time: build the digest from the
  /// database AS IT IS NOW, post it (or withdraw the predicted notice when
  /// nothing is due), then arm tomorrow. Returns the posted digest.
  Future<DueDigest?> runDailyTask({
    required int minuteOfDay,
    DateTime? now,
  }) async {
    final DateTime at = now ?? _now();
    final List<TodoRow> todos = await _loadTodos();
    final DueDigest? digest = buildDueDigest(todos, at);
    if (digest == null) {
      await _port.withdraw();
    } else {
      await _port.post(digest);
    }
    await scheduleNext(minuteOfDay: minuteOfDay, now: at);
    return digest;
  }
}

/// `Platform.isAndroid` behind a provider so the Settings section can be
/// shown on a Windows/Linux test host and hidden there in production.
final Provider<bool> isAndroidProvider =
    Provider<bool>((ref) => Platform.isAndroid);

/// The platform port. Production overrides this in `main()` with the real
/// Android implementation; the default throws so a test that forgets to
/// supply a fake fails loudly instead of touching a plugin.
final Provider<DueReminderPort> dueReminderPortProvider =
    Provider<DueReminderPort>(
  (ref) => throw UnimplementedError(
    'dueReminderPortProvider must be overridden',
  ),
);

final Provider<DueReminderScheduler> dueReminderSchedulerProvider =
    Provider<DueReminderScheduler>(
  (ref) => DueReminderScheduler(
    port: ref.watch(dueReminderPortProvider),
    loadTodos: () => ref.read(todoRepositoryProvider).listTodos(),
  ),
);
