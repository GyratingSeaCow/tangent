// SPDX-License-Identifier: AGPL-3.0-or-later
/// Exact per-todo due notifications.
///
/// The daily digest remains a separate feature. This scheduler owns the
/// deterministic todo-id -> notification-id mapping and reconciliation of the
/// platform's pending set against the database. Past due instants are never
/// armed, so a restore or first sync cannot create a notification storm.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local_db.dart';
import '../data/todo_repository.dart';

const String kTodoDueChannelId = 'todo_due_times';
const String kTodoDueChannelName = 'To-do due times';
const String kTodoDoneActionId = 'todo_mark_done';
const String kTodoPayloadPrefix = 'todo:';

/// Native exact-alarm permission broadcasts enqueue this WorkManager task.
/// It is intentionally separate from network sync: re-arming is local and
/// must work offline without opening the app.
const String kExactAlarmReconcileTaskName =
    'tangent.exactAlarmPermission.reconcile';
const String kTodoDuePermissionRequestedKey = 'todo_due_permissions_requested';

String todoNotificationPayload(String todoId) => '$kTodoPayloadPrefix$todoId';

String? todoIdFromNotificationPayload(String? payload) {
  if (payload == null || !payload.startsWith(kTodoPayloadPrefix)) return null;
  final String id = payload.substring(kTodoPayloadPrefix.length);
  return id.isEmpty ? null : id;
}

abstract class TodoDueNotificationPort {
  Future<bool> requestNotificationPermission();
  Future<bool> requestExactAlarmPermission();
  Future<bool> canScheduleExact();
  Future<Set<int>> pendingTodoNotificationIds();
  Future<void> scheduleTodo({
    required int notificationId,
    required String todoId,
    required String title,
    required DateTime fireAt,
    required bool exact,
  });
  Future<void> cancelTodo(int notificationId);
}

class TodoDueNotificationScheduler {
  TodoDueNotificationScheduler({
    required TodoDueNotificationPort port,
    required Future<List<TodoRow>> Function() loadTodos,
    DateTime Function()? now,
    int Function(String value)? hash,
  }) : _port = port,
       _loadTodos = loadTodos,
       _now = now ?? DateTime.now,
       _hash = hash ?? stableTodoNotificationHash;

  final TodoDueNotificationPort _port;
  final Future<List<TodoRow>> Function() _loadTodos;
  final DateTime Function() _now;
  final int Function(String value) _hash;

  /// Point-of-use permission request. Call only after the user confirms the
  /// first due date/time, never during startup reconciliation.
  Future<void> requestPermissionsForDueTime() async {
    await _port.requestNotificationPermission();
    await _port.requestExactAlarmPermission();
  }

  Future<bool> exactAllowed() => _port.canScheduleExact();

  Future<bool> requestExactAlarmPermission() =>
      _port.requestExactAlarmPermission();

  /// Replaces the platform pending set with all future, live, open todos.
  Future<void> reconcile() async {
    final DateTime at = _now();
    final List<TodoRow> rows = await _loadTodos();
    final List<TodoRow> desired = rows
        .where((TodoRow row) {
          if (row.doneAt != null || row.deletedAt != null) return false;
          final DateTime? due = dueDateTime(row);
          return due != null && due.isAfter(at);
        })
        .toList(growable: false);
    final Map<String, int> ids = notificationIdsFor(
      desired.map((TodoRow row) => row.id),
      hash: _hash,
    );
    final Set<int> pending = await _port.pendingTodoNotificationIds();
    final Set<int> wanted = ids.values.toSet();
    for (final int stale in pending.difference(wanted)) {
      await _port.cancelTodo(stale);
    }
    final bool exact = await _port.canScheduleExact();
    for (final TodoRow row in desired) {
      await _port.scheduleTodo(
        notificationId: ids[row.id]!,
        todoId: row.id,
        title: row.body,
        fireAt: dueDateTime(row)!,
        exact: exact,
      );
    }
  }

  static DateTime? dueDateTime(TodoRow row) {
    final String? date = row.dueDate;
    if (date == null) return null;
    final List<String> dateParts = date.split('-');
    final List<String> timeParts = (row.dueTime ?? defaultTodoDueTime).split(
      ':',
    );
    if (dateParts.length != 3 || timeParts.length != 2) return null;
    final int? year = int.tryParse(dateParts[0]);
    final int? month = int.tryParse(dateParts[1]);
    final int? day = int.tryParse(dateParts[2]);
    final int? hour = int.tryParse(timeParts[0]);
    final int? minute = int.tryParse(timeParts[1]);
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        hour > 23 ||
        minute > 59) {
      return null;
    }
    final DateTime value = DateTime(year, month, day, hour, minute);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  }

  /// Deterministic and collision-safe for the complete current todo set.
  /// Sorting makes the linear-probe result independent of query order; adding
  /// a new colliding id can move later assignments, so ids are not per-todo
  /// stable across different sets. Reconciliation repairs the pending set.
  static Map<String, int> notificationIdsFor(
    Iterable<String> todoIds, {
    int Function(String value)? hash,
  }) {
    final int Function(String value) hasher =
        hash ?? stableTodoNotificationHash;
    final List<String> sorted = todoIds.toSet().toList()..sort();
    final Map<String, int> result = <String, int>{};
    final Set<int> used = <int>{};
    for (final String todoId in sorted) {
      int candidate = 10000 + (hasher(todoId) % 2000000000);
      while (!used.add(candidate)) {
        candidate = candidate == 2000009999 ? 10000 : candidate + 1;
      }
      result[todoId] = candidate;
    }
    return result;
  }
}

/// 32-bit FNV-1a reduced to a positive Android notification id range.
int stableTodoNotificationHash(String value) {
  int hash = 0x811c9dc5;
  for (final int unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Owns reconciliation for every local database mutation, including sync
/// pulls. The database stream is the authoritative cross-repository seam.
class TodoDueNotificationOwner {
  TodoDueNotificationOwner({
    required TodoRepository repository,
    required TodoDueNotificationScheduler scheduler,
  }) : _scheduler = scheduler {
    _subscription = repository.watchTodos().listen((_) => reconcile());
  }

  final TodoDueNotificationScheduler _scheduler;
  late final StreamSubscription<List<TodoRow>> _subscription;
  Future<void>? _running;
  bool _again = false;

  Future<void> reconcile() {
    final Future<void>? running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final Future<void> started = _drain();
    _running = started;
    return started.whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    do {
      _again = false;
      await _scheduler.reconcile();
    } while (_again);
  }

  Future<void> dispose() => _subscription.cancel();
}

final Provider<TodoDueNotificationPort> todoDueNotificationPortProvider =
    Provider<TodoDueNotificationPort>(
      (Ref ref) => throw UnimplementedError(
        'todoDueNotificationPortProvider must be overridden',
      ),
    );

final Provider<TodoDueNotificationScheduler>
todoDueNotificationSchedulerProvider = Provider<TodoDueNotificationScheduler>((
  Ref ref,
) {
  return TodoDueNotificationScheduler(
    port: ref.watch(todoDueNotificationPortProvider),
    loadTodos: () => ref.read(todoRepositoryProvider).listTodos(),
  );
});

/// Shared point-of-use gate for picker-created and voice-created timed todos.
/// The callback is injectable through Riverpod, and the persisted attempt bit
/// prevents repeated OS prompts after the user has made a choice.
final Provider<Future<void> Function()> todoDuePermissionRequesterProvider =
    Provider<Future<void> Function()>((Ref ref) {
      return () async {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(kTodoDuePermissionRequestedKey) == true) return;
        await ref
            .read(todoDueNotificationSchedulerProvider)
            .requestPermissionsForDueTime();
        await prefs.setBool(kTodoDuePermissionRequestedKey, true);
      };
    });

final Provider<TodoDueNotificationOwner> todoDueNotificationOwnerProvider =
    Provider<TodoDueNotificationOwner>((Ref ref) {
      final TodoDueNotificationOwner owner = TodoDueNotificationOwner(
        repository: ref.read(todoRepositoryProvider),
        scheduler: ref.watch(todoDueNotificationSchedulerProvider),
      );
      unawaited(owner.reconcile());
      ref.onDispose(owner.dispose);
      return owner;
    });
