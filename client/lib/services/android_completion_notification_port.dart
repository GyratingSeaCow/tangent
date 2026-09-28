// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'android_transcription_notification_port.dart'
    show AndroidShadeNotifications;
import 'completion_notifications.dart';

/// Tap payload prefix. The response callback (`main._onNotificationTap`) and
/// the cold-start launch details both carry it; `dumpIdFromPayload` is the
/// one parser for both.
const String completionNotificationPayloadPrefix = 'dump:';

/// `dump:<id>` → id; anything else → null.
String? dumpIdFromNotificationPayload(String? payload) {
  if (payload == null ||
      !payload.startsWith(completionNotificationPayloadPrefix)) {
    return null;
  }
  final String id =
      payload.substring(completionNotificationPayloadPrefix.length).trim();
  return id.isEmpty ? null : id;
}

/// The real Android completion notices (spec 2026-09-28 N1), behind
/// [CompletionNotificationPort]. Same plugin plumbing as the progress
/// notice; its own channel so the user can silence "Finished work" without
/// losing progress, or the reverse.
class AndroidCompletionNotificationPort implements CompletionNotificationPort {
  AndroidCompletionNotificationPort({
    FlutterLocalNotificationsPlugin? plugin,
    this.channelId = 'completion',
    this.channelName = 'Finished work',
    this.channelDescription =
        'Announces finished transcriptions and AI notes.',
  }) : _shade = AndroidShadeNotifications(
          plugin: plugin,
          feature: 'completion notification',
        );

  final AndroidShadeNotifications _shade;
  final String channelId;
  final String channelName;
  final String channelDescription;

  @override
  Future<void> show(CompletionNotice notice) => _shade.post(
        notice.notificationId,
        notice.title,
        notice.body,
        AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          icon: AndroidShadeNotifications.icon,
          color: AndroidShadeNotifications.accent,
          // A result, not progress: it may sound once and show a heads-up
          // card, because the user left the screen to wait for exactly this.
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // Tapping opens the recording (N2) and the notice has done its job.
          autoCancel: true,
          ongoing: false,
        ),
        payload: '$completionNotificationPayloadPrefix${notice.dumpId}',
      );

  @override
  Future<void> cancel(int notificationId) => _shade.cancel(notificationId);
}
