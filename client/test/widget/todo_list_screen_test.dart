// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/todo/todo_list_screen.dart';
import 'package:tangent/services/todo_sections.dart';

/// To Do arc Phase 1: the To Do screen against a real in-memory database —
/// quick-add chained entry, toggle moving rows, undo restore, collapsed
/// Done. The sectioning clock is pinned so "today" never shifts under a
/// slow test runner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime fixedNow = DateTime(2026, 9, 26, 15, 30);
  late LocalDb db;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    todoClock = () => fixedNow;
  });

  tearDown(() async {
    todoClock = DateTime.now;
    await db.close();
  });

  Future<TodoRepository> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[localDbProvider.overrideWithValue(db)],
        child: const MaterialApp(home: TodoListScreen()),
      ),
    );
    await tester.pump();
    return TodoRepository(db: db);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('quick-add', () {
    testWidgets('submit adds the item, clears the field, and KEEPS the '
        'keyboard for chained entry', (tester) async {
      await mount(tester);

      await tester.tap(find.byKey(TodoListScreen.quickAddFieldKey));
      await tester.pump();
      await tester.enterText(
        find.byKey(TodoListScreen.quickAddFieldKey),
        'buy thermal paste',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(find.text('buy thermal paste'), findsOneWidget);
      final TextField field =
          tester.widget(find.byKey(TodoListScreen.quickAddFieldKey));
      expect(field.controller!.text, isEmpty, reason: 'field clears');
      expect(
        field.focusNode!.hasFocus,
        isTrue,
        reason: 'chained entry: the keyboard must stay up after a submit',
      );

      // And the chain actually works: type the next item immediately.
      await tester.enterText(
        find.byKey(TodoListScreen.quickAddFieldKey),
        'email the customer back',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(find.text('email the customer back'), findsOneWidget);
      expect(field.focusNode!.hasFocus, isTrue);

      await unmount(tester);
    });

    testWidgets('an armed date chip dates the NEXT item only', (tester) async {
      final TodoRepository repo = await mount(tester);

      await tester.tap(find.byKey(TodoListScreen.quickAddDateChipKey));
      await settle(tester);
      // Accept the picker's default (today, from the pinned clock).
      await tester.tap(find.text('OK'));
      await settle(tester);
      await tester.enterText(
        find.byKey(TodoListScreen.quickAddFieldKey),
        'dated item',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await tester.enterText(
        find.byKey(TodoListScreen.quickAddFieldKey),
        'undated item',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      final List<TodoRow> rows = await repo.watchTodos().first;
      expect(
        rows.singleWhere((t) => t.body == 'dated item').dueDate,
        todoDateKey(fixedNow),
      );
      expect(
        rows.singleWhere((t) => t.body == 'undated item').dueDate,
        isNull,
        reason: 'the armed date is spent by the first add',
      );
      expect(find.text('Today (1)'), findsOneWidget);
      expect(find.text('Someday (1)'), findsOneWidget);

      await unmount(tester);
    });
  });

  testWidgets('checking an item strikes it and moves it to Done in the '
      'same frame', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added = await repo.add('do the thing');
    await settle(tester);
    expect(find.text('Someday (1)'), findsOneWidget);

    await tester.tap(find.byKey(Key('todo-check-${added.id}')));
    await settle(tester);

    expect(find.text('Someday (1)'), findsNothing);
    expect(find.text('Done (1)'), findsOneWidget);
    // Row is inside collapsed Done now — expand to check the strike.
    await tester.tap(find.byKey(TodoListScreen.doneHeaderKey));
    await settle(tester);
    final Text text = tester.widget(
      find.descendant(
        of: find.byKey(Key('todo-row-${added.id}')),
        matching: find.text('do the thing'),
      ),
    );
    expect(text.style?.decoration, TextDecoration.lineThrough);

    // Unchecking clears done_at and the row returns.
    await tester.tap(find.byKey(Key('todo-check-${added.id}')));
    await settle(tester);
    expect(find.text('Someday (1)'), findsOneWidget);
    expect((await db.getTodoRow(added.id))!.doneAt, isNull);

    await unmount(tester);
  });

  testWidgets('Done starts collapsed and expands on tap', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow done = await repo.add('finished already');
    await repo.toggle(done.id);
    await settle(tester);

    expect(find.text('Done (1)'), findsOneWidget);
    expect(
      find.text('finished already'),
      findsNothing,
      reason: 'Done is collapsed by default',
    );

    await tester.tap(find.byKey(TodoListScreen.doneHeaderKey));
    await settle(tester);
    expect(find.text('finished already'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('Delete is soft with a 5 s undo snackbar, and Undo restores '
      'the item', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added = await repo.add('nearly lost');
    await settle(tester);

    await tester.tap(find.byKey(Key('todo-menu-${added.id}')));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);

    expect(find.text('nearly lost'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    final TodoRow deleted = (await db.getTodoRow(added.id))!;
    expect(
      deleted.deletedAt,
      isNotNull,
      reason: 'delete must be SOFT — the row survives for the undo window',
    );

    await tester.tap(find.text('Undo'));
    await settle(tester);

    expect(find.text('nearly lost'), findsOneWidget);
    expect((await db.getTodoRow(added.id))!.deletedAt, isNull);

    // Let the snackbar timer drain so nothing is pending at teardown.
    await tester.pump(const Duration(seconds: 6));
    await unmount(tester);
  });

  testWidgets('sections render in order with counts, empty ones hidden',
      (tester) async {
    final TodoRepository repo = await mount(tester);
    await repo.add('overdue item', dueDate: '2026-09-20');
    await repo.add('today item', dueDate: todoDateKey(fixedNow));
    await repo.add('someday item');
    await settle(tester);

    expect(find.text('Overdue (1)'), findsOneWidget);
    expect(find.text('Today (1)'), findsOneWidget);
    expect(find.text('Someday (1)'), findsOneWidget);
    expect(
      find.text('Upcoming (0)'),
      findsNothing,
      reason: 'empty sections are hidden, not shown as zero',
    );
    expect(find.textContaining('Done'), findsNothing);

    await unmount(tester);
  });

  testWidgets('tapping the text opens inline edit and submit saves it',
      (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added = await repo.add('tpyo');
    await settle(tester);

    await tester.tap(find.text('tpyo'));
    await settle(tester);
    await tester.enterText(
      find.byKey(Key('todo-edit-${added.id}')),
      'typo, fixed',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.text('typo, fixed'), findsOneWidget);
    expect((await db.getTodoRow(added.id))!.body, 'typo, fixed');

    await unmount(tester);
  });

  testWidgets('long-pressing the date chip clears the due date',
      (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added =
        await repo.add('dated', dueDate: todoDateKey(fixedNow));
    await settle(tester);
    expect(find.text('Today (1)'), findsOneWidget);

    await tester.longPress(find.byKey(Key('todo-date-${added.id}')));
    await settle(tester);

    expect(find.text('Today (1)'), findsNothing);
    expect(find.text('Someday (1)'), findsOneWidget);
    expect((await db.getTodoRow(added.id))!.dueDate, isNull);

    await unmount(tester);
  });
}
