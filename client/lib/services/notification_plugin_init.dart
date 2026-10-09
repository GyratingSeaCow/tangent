// SPDX-License-Identifier: AGPL-3.0-or-later
/// One-time initialisation of the shared notifications plugin.
///
/// `FlutterLocalNotificationsPlugin()` is a process-wide singleton and
/// `initialize()` REPLACES its tap callback on every call. Two features
/// (transcription progress, due-date reminders) share it, so whichever
/// initialised second used to silently wipe the other's tap handling. This
/// guard makes the first initialisation the only one; `main()` performs it
/// with the tap router before anything else can.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

bool _initialised = false;

/// Idempotent. The [onResponse] of the FIRST call is the one that sticks.
Future<void> ensureLocalNotificationsInitialised(
  FlutterLocalNotificationsPlugin plugin, {
  void Function(NotificationResponse response)? onResponse,
  void Function(NotificationResponse response)? onBackgroundResponse,
}) async {
  if (_initialised) return;
  _initialised = true;
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: onResponse,
    onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
  );
}
