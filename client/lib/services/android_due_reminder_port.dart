// SPDX-License-Identifier: AGPL-3.0-or-later
/// The real Android [DueReminderPort]: flutter_local_notifications 17.x
/// `zonedSchedule` for the exact alarm plus a workmanager one-off for the
/// fire-time digest. Thin on purpose — every decision lives in the tested
/// scheduler.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import 'due_digest.dart';
import 'due_reminder_scheduler.dart';
import 'notification_plugin_init.dart';

class AndroidDueReminderPort implements DueReminderPort {
  /// The configuration parameters (id, channel, task, payload) default to
  /// the due reminder's own, so existing call sites are untouched; the
  /// morning review builds a second instance over the same plugin with its
  /// own ids (see `morning_review_scheduler.dart`) instead of duplicating
  /// this plugin layer.
  AndroidDueReminderPort({
    FlutterLocalNotificationsPlugin? plugin,
    Workmanager? workmanager,
    void Function(NotificationResponse response)? onResponse,
    void Function(NotificationResponse response)? onBackgroundResponse,
    int notificationId = kDueReminderNotificationId,
    String channelId = kDueReminderChannelId,
    String channelName = kDueReminderChannelName,
    String channelDescription = 'A morning digest of to-dos due today.',
    String taskName = kDueReminderTaskName,
    String payload = kDueReminderPayload,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _workmanager = workmanager ?? Workmanager(),
       _onResponse = onResponse,
       _onBackgroundResponse = onBackgroundResponse,
       _notificationId = notificationId,
       _channelId = channelId,
       _channelName = channelName,
       _channelDescription = channelDescription,
       _taskName = taskName,
       _payload = payload;

  final FlutterLocalNotificationsPlugin _plugin;
  final Workmanager _workmanager;
  final void Function(NotificationResponse response)? _onResponse;
  final void Function(NotificationResponse response)? _onBackgroundResponse;
  final int _notificationId;
  final String _channelId;
  final String _channelName;
  final String _channelDescription;
  final String _taskName;
  final String _payload;

  static const Color _accent = Color(0xFF9B2594);
  bool _tzReady = false;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Plugin init (shared guard) and time-zone database load. zonedSchedule
  /// needs a `tz.local` that matches the device, or "07:00" lands hours off.
  Future<void> ensureReady() async {
    await ensureLocalNotificationsInitialised(
      _plugin,
      onResponse: _onResponse,
      onBackgroundResponse: _onBackgroundResponse,
    );
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    try {
      final String name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e) {
      // Unknown zone name: keep the package default (UTC) rather than
      // failing the whole feature; the workmanager task still corrects.
      debugPrint('tangent.reminders: time zone unavailable: $e');
    }
    _tzReady = true;
  }

  /// Whether the app was cold-started by a reminder tap.
  Future<bool> launchedByReminderTap() async =>
      await launchPayload() == kDueReminderPayload;

  /// The payload of the notification that cold-started the app, or null
  /// for a normal launch. The tap callback never fires for the launching
  /// notification, so every feature that posts a tappable notice routes
  /// its cold start through here.
  Future<String?> launchPayload() async {
    try {
      final NotificationAppLaunchDetails? details = await _plugin
          .getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return details?.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    await ensureReady();
    final PermissionStatus status = await Permission.notification.request();
    return status.isGranted || status.isLimited;
  }

  @override
  Future<bool> canScheduleExact() async {
    await ensureReady();
    try {
      // Null on Android < 12, where exact alarms need no permission.
      return await _android?.canScheduleExactNotifications() ?? true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    await ensureReady();
    try {
      return await _android?.requestExactAlarmsPermission() ?? true;
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details() => NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      icon: '@drawable/ic_notification',
      color: _accent,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
    ),
  );

  @override
  Future<void> schedule({
    required DateTime fireAt,
    required DueDigest? digest,
    required bool exact,
  }) async {
    try {
      await ensureReady();
      await _plugin.cancel(_notificationId);
      if (digest != null) {
        await _plugin.zonedSchedule(
          _notificationId,
          digest.title,
          digest.body,
          tz.TZDateTime.from(fireAt, tz.local),
          _details(),
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: _payload,
        );
      }
      Duration delay = fireAt.difference(DateTime.now());
      if (delay.isNegative) delay = Duration.zero;
      await _workmanager.registerOneOffTask(
        _taskName,
        _taskName,
        initialDelay: delay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (error, stack) {
      _report('schedule', error, stack);
    }
  }

  @override
  Future<void> post(DueDigest digest) async {
    try {
      await ensureReady();
      await _plugin.show(
        _notificationId,
        digest.title,
        digest.body,
        _details(),
        payload: _payload,
      );
    } catch (error, stack) {
      _report('post', error, stack);
    }
  }

  @override
  Future<void> withdraw() async {
    try {
      await _plugin.cancel(_notificationId);
    } catch (error, stack) {
      _report('withdraw', error, stack);
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _plugin.cancel(_notificationId);
      await _workmanager.cancelByUniqueName(_taskName);
    } catch (error, stack) {
      _report('cancel', error, stack);
    }
  }

  @override
  bool get canOpenSystemSettings => true;

  @override
  Future<void> openSystemSettings() async {
    try {
      await openAppSettings();
    } catch (error, stack) {
      _report('open settings for', error, stack);
    }
  }

  void _report(String operation, Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'tangent',
        context: ErrorDescription(
          'while trying to $operation the due-date reminder',
        ),
      ),
    );
  }
}
