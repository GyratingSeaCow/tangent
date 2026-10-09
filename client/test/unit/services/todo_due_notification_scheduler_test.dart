// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/services/todo_due_notification_scheduler.dart';
import 'package:tangent/services/todo_notification_action_handler.dart';

class _ScheduledTodo {
  const _ScheduledTodo({
    required this.notificationId,
    required this.todoId,
    required this.title,
    required this.fireAt,
    required this.exact,
  });

  final int notificationId;
  final String todoId;
  final String title;
  final DateTime fireAt;
  final bool exact;
}

class _FakeTodoDuePort implements TodoDueNotificationPort {
  bool exact = true;
  bool notificationPermission = true;
  bool exactPermission = true;
  int notificationPermissionRequests = 0;
  int exactPermissionRequests = 0;
  final Map<int, _ScheduledTodo> scheduled = <int, _ScheduledTodo>{};
  final List<int> cancelled = <int>[];
  final StreamController<_ScheduledTodo> events =
      StreamController<_ScheduledTodo>.broadcast();

  @override
  Future<bool> requestNotificationPermission() async {
    notificationPermissionRequests++;
    return notificationPermission;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactPermissionRequests++;
    return exactPermission;
  }

  @override
  Future<bool> canScheduleExact() async => exact;

  @override
  Future<Set<int>> pendingTodoNotificationIds() async => scheduled.keys.toSet();

  @override
  Future<void> scheduleTodo({
    required int notificationId,
    required String todoId,
    required String title,
    required DateTime fireAt,
    required bool exact,
  }) async {
    final _ScheduledTodo value = _ScheduledTodo(
      notificationId: notificationId,
      todoId: todoId,
      title: title,
      fireAt: fireAt,
      exact: exact,
    );
    scheduled[notificationId] = value;
    events.add(value);
  }

  @override
  Future<void> cancelTodo(int notificationId) async {
    cancelled.add(notificationId);
    scheduled.remove(notificationId);
  }

  Future<void> close() => events.close();
}

void main() {
  late LocalDb db;
  late TodoRepository repo;
  late _FakeTodoDuePort port;
  late TodoDueNotificationScheduler scheduler;
  int nextId = 0;
  final DateTime now = DateTime(2026, 10, 9, 8);

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    repo = TodoRepository(
      db: db,
      idFactory: () => 'todo-${nextId++}',
      now: () => now,
    );
    port = _FakeTodoDuePort();
    scheduler = TodoDueNotificationScheduler(
      port: port,
      loadTodos: repo.listTodos,
      now: () => now,
    );
  });

  tearDown(() async {
    await port.close();
    await db.close();
  });

  test(
    'reconcile schedules only future live open todos and cancels stale',
    () async {
      final TodoRow future = await repo.add(
        'future',
        dueDate: '2026-10-09',
        dueTime: '08:01',
      );
      await repo.add('past', dueDate: '2026-10-09', dueTime: '07:59');
      await repo.add('undated');
      final TodoRow done = await repo.add(
        'done',
        dueDate: '2026-10-10',
        dueTime: '12:00',
      );
      await repo.toggle(done.id);
      final TodoRow deleted = await repo.add(
        'deleted',
        dueDate: '2026-10-10',
        dueTime: '13:00',
      );
      await repo.softDelete(deleted.id);
      port.scheduled[777] = _ScheduledTodo(
        notificationId: 777,
        todoId: 'gone',
        title: 'gone',
        fireAt: now.add(const Duration(hours: 1)),
        exact: true,
      );

      await scheduler.reconcile();

      expect(port.cancelled, contains(777));
      expect(port.scheduled.values.map((value) => value.todoId), <String>[
        future.id,
      ]);
      final _ScheduledTodo scheduled = port.scheduled.values.single;
      expect(scheduled.fireAt, DateTime(2026, 10, 9, 8, 1));
      expect(scheduled.exact, isTrue);
      expect(scheduled.title, 'future');
    },
  );

  test('edit, complete, uncomplete, delete, and undelete reconcile', () async {
    final TodoRow todo = await repo.add(
      'mutable',
      dueDate: '2026-10-10',
      dueTime: '09:00',
    );
    await scheduler.reconcile();
    final int id = port.scheduled.keys.single;

    await repo.setDueDate(todo.id, '2026-10-11', dueTime: '14:30');
    await scheduler.reconcile();
    expect(port.scheduled[id]!.fireAt, DateTime(2026, 10, 11, 14, 30));

    await repo.toggle(todo.id);
    await scheduler.reconcile();
    expect(port.scheduled, isEmpty);
    expect(port.cancelled, contains(id));

    await repo.toggle(todo.id);
    await scheduler.reconcile();
    expect(port.scheduled[id], isNotNull);

    await repo.softDelete(todo.id);
    await scheduler.reconcile();
    expect(port.scheduled, isEmpty);

    await repo.restore(todo.id);
    await scheduler.reconcile();
    expect(port.scheduled[id], isNotNull);
  });

  test(
    'permissions are requested only through the point-of-use method',
    () async {
      await scheduler.reconcile();
      expect(port.notificationPermissionRequests, 0);
      expect(port.exactPermissionRequests, 0);

      await scheduler.requestPermissionsForDueTime();

      expect(port.notificationPermissionRequests, 1);
      expect(port.exactPermissionRequests, 1);
    },
  );

  test('shared point-of-use requester persists one permission attempt', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        todoDueNotificationSchedulerProvider.overrideWithValue(scheduler),
      ],
    );
    addTearDown(container.dispose);
    final Future<void> Function() request =
        container.read(todoDuePermissionRequesterProvider);

    await request();
    await request();

    expect(port.notificationPermissionRequests, 1);
    expect(port.exactPermissionRequests, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        kTodoDuePermissionRequestedKey,
      ),
      isTrue,
    );
  });

  test('notification ids are deterministic, positive, and collision-safe', () {
    final Map<String, int> forward =
        TodoDueNotificationScheduler.notificationIdsFor(<String>[
          'c',
          'a',
          'b',
        ], hash: (_) => 1);
    final Map<String, int> reverse =
        TodoDueNotificationScheduler.notificationIdsFor(<String>[
          'b',
          'c',
          'a',
        ], hash: (_) => 1);

    expect(forward, reverse);
    expect(forward.values.toSet(), hasLength(3));
    expect(forward.values.every((int value) => value > 0), isTrue);
  });

  test('database owner reschedules a remote due-time change', () async {
    final TodoRow todo = await repo.add(
      'remote mutable',
      dueDate: '2026-10-10',
      dueTime: '09:00',
    );
    final TodoDueNotificationOwner owner = TodoDueNotificationOwner(
      repository: repo,
      scheduler: scheduler,
    );
    addTearDown(owner.dispose);
    await owner.reconcile();
    final Future<_ScheduledTodo> changed = port.events.stream.firstWhere(
      (_ScheduledTodo value) =>
          value.todoId == todo.id && value.fireAt.hour == 16,
    );

    await db.applyRemoteTodo(
      id: todo.id,
      text: todo.body,
      createdAt: todo.createdAt,
      updatedAt: '2027-01-01T00:00:00.000Z',
      dueDate: '2026-10-12',
      dueTime: '16:45',
      seq: 9,
    );

    expect((await changed).fireAt, DateTime(2026, 10, 12, 16, 45));
  });

  test('mark done action is idempotent and uses rightmost lane', () async {
    final TodoRow todo = await repo.add(
      'action',
      dueDate: '2026-10-10',
      dueTime: '10:00',
    );
    final List<int> cancelled = <int>[];
    final TodoNotificationActionHandler handler = TodoNotificationActionHandler(
      repository: repo,
      cancelNotification: (int id) async => cancelled.add(id),
    );

    expect(
      await handler.handle(
        actionId: kTodoDoneActionId,
        payload: todoNotificationPayload(todo.id),
        notificationId: 42,
      ),
      isTrue,
    );

    final TodoRow done = (await db.getTodoRow(todo.id))!;
    final List<TodoColumnRow> columns = await repo.listColumns();
    expect(done.doneAt, isNotNull);
    expect(done.columnId, columns.last.id);
    expect(done.syncDirty, isTrue);
    expect(cancelled, <int>[42]);

    await handler.handle(
      actionId: kTodoDoneActionId,
      payload: todoNotificationPayload(todo.id),
      notificationId: 43,
    );
    expect((await db.getTodoRow(todo.id))!.doneAt, done.doneAt);
    expect(cancelled, <int>[42, 43]);
  });
}
