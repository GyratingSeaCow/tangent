// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import 'todo_due_notification_scheduler.dart';

abstract class DesktopTodoNotifier {
  Future<void> setup();
  Future<void> show({
    required String todoId,
    required String title,
    required VoidCallback onClick,
    required VoidCallback onMarkDone,
  });
  Future<void> close(String todoId);
}

class LocalDesktopTodoNotifier implements DesktopTodoNotifier {
  LocalDesktopTodoNotifier({required this.appName});

  final String appName;
  final Map<String, LocalNotification> _shown = <String, LocalNotification>{};
  bool _ready = false;

  @override
  Future<void> setup() async {
    if (_ready) return;
    await localNotifier.setup(
      appName: appName,
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _ready = true;
  }

  @override
  Future<void> show({
    required String todoId,
    required String title,
    required VoidCallback onClick,
    required VoidCallback onMarkDone,
  }) async {
    await setup();
    await close(todoId);
    final LocalNotification notification =
        LocalNotification(
            identifier: 'todo-due-$todoId',
            title: title,
            body: 'Due now',
            actions: <LocalNotificationAction>[
              LocalNotificationAction(text: 'Mark done'),
            ],
          )
          ..onClick = onClick
          ..onClickAction = (int index) {
            if (index == 0) onMarkDone();
          };
    _shown[todoId] = notification;
    await notification.show();
  }

  @override
  Future<void> close(String todoId) async {
    final LocalNotification? notification = _shown.remove(todoId);
    if (notification != null) await notification.destroy();
  }
}

typedef TodoTimerFactory = Timer Function(Duration delay, void Function() fire);

class DesktopTodoDueNotificationPort implements TodoDueNotificationPort {
  DesktopTodoDueNotificationPort({
    required DesktopTodoNotifier notifier,
    required void Function(String todoId) onClick,
    required Future<void> Function(String todoId, int notificationId)
    onMarkDone,
    DateTime Function()? now,
    TodoTimerFactory? timerFactory,
  }) : _notifier = notifier,
       _onClick = onClick,
       _onMarkDone = onMarkDone,
       _now = now ?? DateTime.now,
       _newTimer = timerFactory ?? _realTimer;

  static Timer _realTimer(Duration delay, void Function() fire) =>
      Timer(delay, fire);

  final DesktopTodoNotifier _notifier;
  final void Function(String todoId) _onClick;
  final Future<void> Function(String todoId, int notificationId) _onMarkDone;
  final DateTime Function() _now;
  final TodoTimerFactory _newTimer;
  final Map<int, Timer> _timers = <int, Timer>{};
  final Map<int, String> _todoIds = <int, String>{};

  Future<void> ensureReady() => _notifier.setup();

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> requestExactAlarmPermission() async => true;

  @override
  Future<bool> canScheduleExact() async => true;

  @override
  Future<Set<int>> pendingTodoNotificationIds() async => _todoIds.keys.toSet();

  @override
  Future<void> scheduleTodo({
    required int notificationId,
    required String todoId,
    required String title,
    required DateTime fireAt,
    required bool exact,
  }) async {
    _timers.remove(notificationId)?.cancel();
    _todoIds[notificationId] = todoId;
    final Duration delay = fireAt.difference(_now());
    if (!delay.isNegative) {
      _timers[notificationId] = _newTimer(delay, () {
        _timers.remove(notificationId);
        unawaited(
          _notifier.show(
            todoId: todoId,
            title: title,
            onClick: () => _onClick(todoId),
            onMarkDone: () {
              unawaited(_onMarkDone(todoId, notificationId));
            },
          ),
        );
      });
    }
  }

  @override
  Future<void> cancelTodo(int notificationId) async {
    _timers.remove(notificationId)?.cancel();
    final String? todoId = _todoIds.remove(notificationId);
    if (todoId != null) await _notifier.close(todoId);
  }
}
