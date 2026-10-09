// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/desktop_todo_due_notification_port.dart';

class _FakeDesktopTodoNotifier implements DesktopTodoNotifier {
  int setups = 0;
  final List<String> shown = <String>[];
  final List<String> closed = <String>[];
  VoidCallback? onClick;
  VoidCallback? onMarkDone;

  @override
  Future<void> setup() async => setups++;

  @override
  Future<void> show({
    required String todoId,
    required String title,
    required VoidCallback onClick,
    required VoidCallback onMarkDone,
  }) async {
    shown.add('$todoId:$title');
    this.onClick = onClick;
    this.onMarkDone = onMarkDone;
  }

  @override
  Future<void> close(String todoId) async => closed.add(todoId);
}

void main() {
  test('desktop todo timer fires exactly and routes click and mark done', () {
    fakeAsync((FakeAsync async) {
      final DateTime start = DateTime(2026, 10, 9, 8);
      final _FakeDesktopTodoNotifier notifier = _FakeDesktopTodoNotifier();
      final List<String> clicked = <String>[];
      final List<(String, int)> completed = <(String, int)>[];
      final DesktopTodoDueNotificationPort port =
          DesktopTodoDueNotificationPort(
            notifier: notifier,
            onClick: clicked.add,
            onMarkDone: (String todoId, int notificationId) async {
              completed.add((todoId, notificationId));
            },
            now: () => start.add(async.elapsed),
            timerFactory: (Duration delay, void Function() fire) =>
                Timer(delay, fire),
          );

      port.scheduleTodo(
        notificationId: 42,
        todoId: 'todo-a',
        title: 'Call Dana',
        fireAt: start.add(const Duration(minutes: 5)),
        exact: true,
      );
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 4, seconds: 59));
      expect(notifier.shown, isEmpty);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(notifier.shown, <String>['todo-a:Call Dana']);

      notifier.onClick!();
      notifier.onMarkDone!();
      async.flushMicrotasks();
      expect(clicked, <String>['todo-a']);
      expect(completed, <(String, int)>[('todo-a', 42)]);
    });
  });

  test(
    'desktop cancel removes a pending timer and closes its notification',
    () {
      fakeAsync((FakeAsync async) {
        final DateTime start = DateTime(2026, 10, 9, 8);
        final _FakeDesktopTodoNotifier notifier = _FakeDesktopTodoNotifier();
        final DesktopTodoDueNotificationPort port =
            DesktopTodoDueNotificationPort(
              notifier: notifier,
              onClick: (_) {},
              onMarkDone: (_, _) async {},
              now: () => start.add(async.elapsed),
              timerFactory: (Duration delay, void Function() fire) =>
                  Timer(delay, fire),
            );

        port.scheduleTodo(
          notificationId: 42,
          todoId: 'todo-a',
          title: 'Call Dana',
          fireAt: start.add(const Duration(minutes: 5)),
          exact: true,
        );
        async.flushMicrotasks();
        port.cancelTodo(42);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));
        expect(notifier.shown, isEmpty);
        expect(notifier.closed, <String>['todo-a']);
      });
    },
  );
}
