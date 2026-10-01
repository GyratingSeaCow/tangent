// SPDX-License-Identifier: AGPL-3.0-or-later
/// Morning-review scheduling (Ask-arc queued item 2), mirroring the daily
/// due-date reminder: [MorningReviewScheduler] owns every DECISION (when
/// the next review fires, what the notification says, whether to post at
/// all) and is fully unit-tested against a fake [DueReminderPort] — the
/// SAME port contract the due reminder uses, deliberately. A reminder port
/// already knows how to arm one daily alarm, post one replaceable notice
/// and cancel both; the morning review needs nothing more, so it reuses
/// the contract with its own notification id, channel and background task
/// (see `AndroidDueReminderPort`'s configuration parameters) rather than
/// growing a parallel plugin layer.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart';
import '../data/settings_store.dart';
import '../screens/home/home_screen.dart' show localDbProvider;
import 'desktop_due_reminder_port.dart' show missedReminderPrefix;
import 'due_digest.dart';
import 'due_reminder_scheduler.dart';
import 'morning_review.dart';

/// Unique name of the background task that posts the review at fire time.
/// Handled by the same WorkManager dispatcher as the due reminder.
const String kMorningReviewTaskName = 'tangent.morningReview.daily';

/// Notification channel. Its own channel, not the due reminder's: Android
/// lets the user silence one without the other.
const String kMorningReviewChannelId = 'morning_review';
const String kMorningReviewChannelName = 'Morning review';

/// Tap payload; `main.dart` just brings the app up — Home IS the review.
const String kMorningReviewPayload = 'morning-review';

/// Fixed id, distinct from the due reminder's 1101: the two notices must
/// replace themselves, never each other.
const int kMorningReviewNotificationId = 1102;

/// Default review time: 08:00 local, stored as minute-of-day.
const int kDefaultMorningReviewMinuteOfDay = 8 * 60;

/// Decisions only; the port does the platform work. See the library doc.
class MorningReviewScheduler {
  MorningReviewScheduler({
    required DueReminderPort port,
    required Future<List<DumpRow>> Function() loadDumps,
    DateTime Function()? now,
    Future<void> Function(String isoDay)? onPosted,
  })  : _port = port,
        _loadDumps = loadDumps,
        _now = now ?? DateTime.now,
        _onPosted = onPosted;

  final DueReminderPort _port;
  final Future<List<DumpRow>> Function() _loadDumps;
  final DateTime Function() _now;

  /// Called with the local `YYYY-MM-DD` after a review was posted at fire
  /// time; production records `SettingsStore.lastMorningReviewShownDay`.
  final Future<void> Function(String isoDay)? _onPosted;

  Future<bool> requestPermission() => _port.requestNotificationPermission();

  Future<bool> exactAllowed() => _port.canScheduleExact();

  Future<void> openSystemSettings() => _port.openSystemSettings();

  bool get canOpenSystemSettings => _port.canOpenSystemSettings;

  /// Arms the next review. Returns the instant it will fire. The digest
  /// handed to the alarm is PREDICTED from the captures as they are now;
  /// the fire-time task replaces it with the truth (Android), and the
  /// desktop port ignores it and builds live at fire time.
  Future<DateTime> scheduleNext({
    required int minuteOfDay,
    DateTime? now,
  }) async {
    final DateTime at = now ?? _now();
    final DateTime fireAt =
        DueReminderScheduler.nextFireTime(at, minuteOfDay);
    final MorningReview? predicted =
        buildMorningReview(await _loadDumps(), fireAt);
    final bool exact = await _port.canScheduleExact();
    await _port.schedule(
      fireAt: fireAt,
      digest: predicted == null ? null : morningReviewNotification(predicted),
      exact: exact,
    );
    return fireAt;
  }

  /// Toggle-off: nothing pending, nothing shown, nothing queued.
  Future<void> cancel() => _port.cancel();

  /// The background task's body, at fire time: build the review from the
  /// database AS IT IS NOW, post it (or withdraw the predicted notice when
  /// yesterday captured nothing), then arm tomorrow.
  Future<DueDigest?> runDailyTask({
    required int minuteOfDay,
    DateTime? now,
  }) async {
    final DateTime at = now ?? _now();
    final MorningReview? review = buildMorningReview(await _loadDumps(), at);
    final DueDigest? digest =
        review == null ? null : morningReviewNotification(review);
    if (digest == null) {
      await _port.withdraw();
    } else {
      await _port.post(digest);
      await _onPosted?.call(isoDate(at));
    }
    await scheduleNext(minuteOfDay: minuteOfDay, now: at);
    return digest;
  }
}

/// K1-style catch-up, on desktop app start: when the review is on, the
/// chosen time has already passed today and no review notification was
/// shown today, build it live and post with the `Missed H:MM · ` prefix,
/// then record the day so the same day never gets it twice. The CARD needs
/// none of this — it computes its standing from the clock whenever Home
/// builds — so this covers only the notification half of the spec.
Future<DueDigest?> runDesktopMorningReviewCatchUp({
  required SettingsStore settings,
  required DueReminderPort port,
  required Future<List<DumpRow>> Function() loadDumps,
  required DateTime now,
}) async {
  if (!settings.morningReviewEnabled) return null;
  final int minuteOfDay = now.hour * 60 + now.minute;
  if (minuteOfDay < settings.morningReviewMinuteOfDay) return null;
  final String today = isoDate(now);
  if (settings.lastMorningReviewShownDay == today) return null;
  final MorningReview? review = buildMorningReview(await loadDumps(), now);
  if (review == null) return null;
  final DueDigest digest = morningReviewNotification(review);
  final DueDigest missed = DueDigest(
    title:
        '${missedReminderPrefix(settings.morningReviewMinuteOfDay)}'
        '${digest.title}',
    body: digest.body,
    dueTodayCount: digest.dueTodayCount,
    overdueCount: digest.overdueCount,
  );
  await port.post(missed);
  await settings.setLastMorningReviewShownDay(today);
  return missed;
}

/// The platform port for the morning review. Production overrides this in
/// `main()` (Android: a second `AndroidDueReminderPort` configured with the
/// morning-review ids; desktop: a second `DesktopDueReminderPort`); the
/// default throws so a test that forgets to supply a fake fails loudly
/// instead of touching a plugin.
final Provider<DueReminderPort> morningReviewPortProvider =
    Provider<DueReminderPort>(
  (ref) => throw UnimplementedError(
    'morningReviewPortProvider must be overridden',
  ),
);

final Provider<MorningReviewScheduler> morningReviewSchedulerProvider =
    Provider<MorningReviewScheduler>(
  (ref) => MorningReviewScheduler(
    port: ref.watch(morningReviewPortProvider),
    loadDumps: () => ref.read(localDbProvider).listDumps(limit: 500),
  ),
);
