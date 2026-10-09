// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_plugin_init.dart';
import 'todo_due_notification_scheduler.dart';

class AndroidTodoDueNotificationPort implements TodoDueNotificationPort {
  AndroidTodoDueNotificationPort({
    FlutterLocalNotificationsPlugin? plugin,
    void Function(NotificationResponse response)? onResponse,
    void Function(NotificationResponse response)? onBackgroundResponse,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _onResponse = onResponse,
       _onBackgroundResponse = onBackgroundResponse;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(NotificationResponse response)? _onResponse;
  final void Function(NotificationResponse response)? _onBackgroundResponse;
  bool _tzReady = false;

  static const Color _accent = Color(0xFF9B2594);

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

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
    } catch (error) {
      debugPrint('tangent.todo-due: time zone unavailable: $error');
    }
    _tzReady = true;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    await ensureReady();
    final PermissionStatus status = await Permission.notification.request();
    return status.isGranted || status.isLimited;
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

  @override
  Future<bool> canScheduleExact() async {
    await ensureReady();
    try {
      return await _android?.canScheduleExactNotifications() ?? true;
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details() => const NotificationDetails(
    android: AndroidNotificationDetails(
      kTodoDueChannelId,
      kTodoDueChannelName,
      channelDescription:
          'A notification when each to-do reaches its due time.',
      icon: '@drawable/ic_notification',
      color: _accent,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          kTodoDoneActionId,
          'Mark done',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    ),
  );

  @override
  Future<Set<int>> pendingTodoNotificationIds() async {
    await ensureReady();
    final List<PendingNotificationRequest> pending = await _plugin
        .pendingNotificationRequests();
    return pending
        .where(
          (PendingNotificationRequest request) =>
              todoIdFromNotificationPayload(request.payload) != null,
        )
        .map((PendingNotificationRequest request) => request.id)
        .toSet();
  }

  @override
  Future<void> scheduleTodo({
    required int notificationId,
    required String todoId,
    required String title,
    required DateTime fireAt,
    required bool exact,
  }) async {
    await ensureReady();
    await _plugin.zonedSchedule(
      notificationId,
      title,
      'Due now',
      tz.TZDateTime.from(fireAt, tz.local),
      _details(),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: todoNotificationPayload(todoId),
    );
  }

  @override
  Future<void> cancelTodo(int notificationId) => _plugin.cancel(notificationId);

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
}
