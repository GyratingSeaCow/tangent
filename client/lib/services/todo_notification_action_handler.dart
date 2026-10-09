// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import '../data/local_db.dart';
import '../data/todo_repository.dart';
import 'todo_due_notification_scheduler.dart';

/// Handles notification actions through the same repository toggle used by
/// the checkbox. That preserves sync-dirty stamping and rightmost-lane filing.
class TodoNotificationActionHandler {
  const TodoNotificationActionHandler({
    required this.repository,
    required this.cancelNotification,
  });

  final TodoRepository repository;
  final Future<void> Function(int notificationId) cancelNotification;

  Future<bool> handle({
    required String? actionId,
    required String? payload,
    required int notificationId,
  }) async {
    if (actionId != kTodoDoneActionId) return false;
    final String? todoId = todoIdFromNotificationPayload(payload);
    if (todoId == null) return false;
    final TodoRow? row = await repository.dbTodo(todoId);
    if (row == null || row.deletedAt != null) {
      await cancelNotification(notificationId);
      return false;
    }
    if (row.doneAt == null) await repository.toggle(todoId);
    await cancelNotification(notificationId);
    return true;
  }
}
