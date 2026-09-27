// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/todo/todo_list_screen.dart';
import 'package:tangent/services/todo_sections.dart';
import 'package:tangent/widgets/folder_picker.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

/// The To Do screen against a real in-memory database — quick-add chained
/// entry, toggle moving rows, undo restore, collapsed Done, and (v1.24.0)
/// shared folders: sections, ⋮ → Move, multi-select, header actions.
///
/// Folders ride the SAME real drift db as the todos (F1: one `folders`
/// table), so "New folder" from the picker is a real createFolder and the
/// header it produces is what Notebooks would show. The sectioning clock is
/// pinned so "today" never shifts under a slow test runner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime fixedNow = DateTime(2026, 9, 26, 15, 30);
  late LocalDb db;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = LocalDb.forTesting(NativeDatabase.memory());
    todoClock = () => fixedNow;
  });

  tearDown(() async {
    todoClock = DateTime.now;
    await db.close();
  });

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<TodoRepository> mount(WidgetTester tester) async {
    sizeView(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[localDbProvider.overrideWithValue(db)],
        child: const MaterialApp(home: TodoListScreen()),
      ),
    );
    await tester.pump();
    // The folders stream's first emission needs its own frame.
    await tester.pumpAndSettle();
    return TodoRepository(db: db);
  }

  /// Mounts a host with a button that PUSHES the screen: only a pushed
  /// route engages `PopScope.canPop`; a `home:` screen never does and the
  /// back-cancels-selection bug hides.
  Future<TodoRepository> mountPushed(WidgetTester tester) async {
    sizeView(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[localDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('host-open'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TodoListScreen(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('host-open')));
    await tester.pumpAndSettle();
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

  double top(WidgetTester tester, Key key) =>
      tester.getTopLeft(find.byKey(key)).dy;

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

    testWidgets('an armed date chip dates the NEXT item only, and a new item '
        'lands unfiled', (tester) async {
      final TodoRepository repo = await mount(tester);

      await tester.tap(find.byKey(TodoListScreen.quickAddDateChipKey));
      // The date picker is a ROUTE with a 150 ms transition, longer than the
      // 50 ms `settle` helper the rest of this file uses.
      await tester.pumpAndSettle();
      // Accept the picker's default (today, from the pinned clock).
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
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

      // One-shot read, NOT `watchTodos().first`: a drift stream's first
      // emission rides a `Timer.run`, which the widget test's fake clock only
      // fires on a pump — so `.first` here awaited forever (a 10-minute
      // TimeoutException that took the rest of this file down with it).
      final List<TodoRow> rows = await repo.listTodos();
      final TodoRow dated = rows.singleWhere((t) => t.body == 'dated item');
      expect(dated.dueDate, todoDateKey(fixedNow));
      expect(dated.folderId, isNull, reason: 'new items land unfiled');
      expect(
        rows.singleWhere((t) => t.body == 'undated item').dueDate,
        isNull,
        reason: 'the armed date is spent by the first add',
      );
      // The time chip says Today on the dated row and nothing on the other.
      expect(
        find.descendant(
          of: find.byKey(Key('todo-row-${dated.id}')),
          matching: find.text('Today'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(Key('todo-chip-${dated.id}')), findsOneWidget);

      await unmount(tester);
    });
  });

  testWidgets('checking an item strikes it and moves it to Done in the '
      'same frame', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added = await repo.add('do the thing');
    await settle(tester);
    expect(find.textContaining('Done'), findsNothing);

    await tester.tap(find.byKey(Key('todo-check-${added.id}')));
    await settle(tester);

    expect(find.text('Done (1)'), findsOneWidget);
    expect(
      find.text('do the thing'),
      findsNothing,
      reason: 'the row is inside collapsed Done now',
    );
    // Expand to check the strike.
    await tester.tap(find.byKey(TodoListScreen.doneHeaderKey));
    await settle(tester);
    final Text text = tester.widget(
      find.descendant(
        of: find.byKey(Key('todo-row-${added.id}')),
        matching: find.text('do the thing'),
      ),
    );
    expect(text.style?.decoration, TextDecoration.lineThrough);

    // Unchecking clears done_at and the row returns to the open list.
    await tester.tap(find.byKey(Key('todo-check-${added.id}')));
    await settle(tester);
    expect(find.text('Done (1)'), findsNothing);
    expect(find.text('do the thing'), findsOneWidget);
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

  testWidgets('⋮ → Delete is soft with a 5 s undo snackbar, and Undo '
      'restores the item', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added = await repo.add('nearly lost');
    await settle(tester);

    await tester.tap(find.byKey(Key('todo-menu-${added.id}')));
    // The action sheet is a ROUTE (same story as the date picker above):
    // its transition outlives the 50 ms `settle`, and tapping 'Delete'
    // mid-animation misses the hit test entirely.
    await tester.pumpAndSettle();
    // Canonical order, with rename relabelled Edit for this screen.
    expect(find.byKey(ItemActionSheet.keyFor(ItemAction.move)), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.delete)));
    await tester.pumpAndSettle();

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

  testWidgets('with no folders the list is flat, in due-date order, with a '
      'time chip per row (Overdue red / Today / date)', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow someday = await repo.add('someday item');
    final TodoRow overdue = await repo.add('overdue item', dueDate: '2026-09-20');
    final TodoRow later = await repo.add('later item', dueDate: '2026-10-03');
    final TodoRow today =
        await repo.add('today item', dueDate: todoDateKey(fixedNow));
    await settle(tester);

    expect(find.byKey(TodoListScreen.unfiledHeaderKey), findsNothing);
    expect(find.text('No folder (4)'), findsNothing);
    expect(find.textContaining('Done'), findsNothing);
    final double yOverdue = top(tester, Key('todo-row-${overdue.id}'));
    final double yToday = top(tester, Key('todo-row-${today.id}'));
    final double yLater = top(tester, Key('todo-row-${later.id}'));
    final double ySomeday = top(tester, Key('todo-row-${someday.id}'));
    expect(yOverdue, lessThan(yToday));
    expect(yToday, lessThan(yLater));
    expect(yLater, lessThan(ySomeday), reason: 'undated last');

    final Text overdueChip = tester.widget(
      find.descendant(
        of: find.byKey(Key('todo-chip-${overdue.id}')),
        matching: find.byType(Text),
      ),
    );
    expect(overdueChip.data, 'Overdue · 2026-09-20');
    expect(
      overdueChip.style?.color,
      Theme.of(tester.element(find.byType(TodoListScreen))).colorScheme.error,
    );
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('2026-10-03'), findsOneWidget);
    expect(find.byKey(Key('todo-chip-${someday.id}')), findsNothing);

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

    // ⋮ → Edit opens the same inline editor.
    await tester.tap(find.byKey(Key('todo-menu-${added.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('todo-edit-${added.id}')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('long-pressing the date chip clears the due date (still a '
      'chip gesture, not selection)', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow added =
        await repo.add('dated', dueDate: todoDateKey(fixedNow));
    await settle(tester);
    expect(find.text('Today'), findsOneWidget);

    await tester.longPress(find.byKey(Key('todo-chip-${added.id}')));
    await settle(tester);

    expect(find.text('Today'), findsNothing);
    expect(find.byKey(Key('todo-chip-${added.id}')), findsNothing);
    expect((await db.getTodoRow(added.id))!.dueDate, isNull);
    expect(find.textContaining('selected'), findsNothing);
    expect(find.byKey(TodoListScreen.selectMoveKey), findsNothing);

    await unmount(tester);
  });

  group('folders', () {
    testWidgets('folder sections: alphabetical headers with counts, empty '
        'folders shown, No folder last, one Done at the bottom; headers '
        'collapse on tap', (tester) async {
      final TodoRepository repo = await mount(tester);
      final String work = await db.createFolder(name: 'work');
      final String shop = await db.createFolder(name: 'Shop');
      final TodoRow inShop = await repo.add('buy filament');
      await repo.moveToFolder(inShop.id, shop);
      final TodoRow loose = await repo.add('loose item');
      final TodoRow doneInWork = await repo.add('finished');
      await repo.moveToFolder(doneInWork.id, work);
      await repo.toggle(doneInWork.id);
      await tester.pumpAndSettle();

      expect(find.text('Shop (1)'), findsOneWidget);
      expect(find.text('work (0)'), findsOneWidget, reason: 'empty shown');
      expect(find.text('No folder (1)'), findsOneWidget);
      expect(find.text('Done (1)'), findsOneWidget);
      final double yShop = top(tester, TodoListScreen.folderHeaderKey(shop));
      final double yWork = top(tester, TodoListScreen.folderHeaderKey(work));
      final double yUnfiled = top(tester, TodoListScreen.unfiledHeaderKey);
      final double yDone = top(tester, TodoListScreen.doneHeaderKey);
      expect(yShop, lessThan(yWork), reason: 'case-insensitive alphabetical');
      expect(yWork, lessThan(yUnfiled));
      expect(yUnfiled, lessThan(yDone));
      expect(top(tester, Key('todo-row-${inShop.id}')), lessThan(yWork));
      expect(top(tester, Key('todo-row-${loose.id}')), greaterThan(yUnfiled));

      await tester.tap(find.byKey(TodoListScreen.folderHeaderKey(shop)));
      await settle(tester);
      expect(find.text('buy filament'), findsNothing, reason: 'collapsed');
      await tester.tap(find.byKey(TodoListScreen.folderHeaderKey(shop)));
      await settle(tester);
      expect(find.text('buy filament'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('⋮ → Move → picker files the row under the chosen folder, '
        'and New folder creates a SHARED folder row', (tester) async {
      final TodoRepository repo = await mount(tester);
      final String shop = await db.createFolder(name: 'Shop');
      final TodoRow item = await repo.add('buy filament');
      await tester.pumpAndSettle();
      expect(find.text('No folder (1)'), findsOneWidget);

      await tester.tap(find.byKey(Key('todo-menu-${item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.move)));
      await tester.pumpAndSettle();
      expect(find.text('Move to'), findsOneWidget, reason: 'the shared picker');
      await tester.tap(find.byKey(FolderPicker.folderKey(shop)));
      await tester.pumpAndSettle();

      expect((await db.getTodoRow(item.id))!.folderId, shop);
      expect(find.text('Shop (1)'), findsOneWidget);
      expect(find.text('No folder (1)'), findsNothing);
      expect(
        top(tester, Key('todo-row-${item.id}')),
        greaterThan(top(tester, TodoListScreen.folderHeaderKey(shop))),
      );

      // New folder… from the same picker.
      await tester.tap(find.byKey(Key('todo-menu-${item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.move)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FolderPicker.newFolderKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(FolderPicker.newFolderFieldKey),
        'Workshop',
      );
      await tester.tap(find.byKey(FolderPicker.newFolderCreateKey));
      await tester.pumpAndSettle();

      final List<Folder> folders = await db.select(db.folders).get();
      final Folder workshop = folders.singleWhere((f) => f.name == 'Workshop');
      expect((await db.getTodoRow(item.id))!.folderId, workshop.id);
      expect(find.text('Workshop (1)'), findsOneWidget);
      expect(find.text('Shop (0)'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('folder header long-press opens the shared rename/delete '
        'sheet — never selection; No folder and Done have no actions',
        (tester) async {
      final TodoRepository repo = await mount(tester);
      final String shop = await db.createFolder(name: 'Shop');
      final TodoRow item = await repo.add('loose');
      final TodoRow done = await repo.add('finished');
      await repo.toggle(done.id);
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(TodoListScreen.folderHeaderKey(shop)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder-action-rename')), findsOneWidget);
      expect(find.byKey(const Key('folder-action-delete')), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
      expect(find.byKey(TodoListScreen.selectMoveKey), findsNothing);
      expect(find.byKey(Key('todo-menu-${item.id}')), findsOneWidget);

      await tester.tap(find.byKey(const Key('folder-action-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder-rename-field')),
        'Garage',
      );
      await tester.tap(find.byKey(const Key('folder-rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('Garage (0)'), findsOneWidget);

      await tester.longPress(find.byKey(TodoListScreen.unfiledHeaderKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder-action-rename')), findsNothing);
      expect(find.textContaining('selected'), findsNothing);
      await tester.longPress(find.byKey(TodoListScreen.doneHeaderKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder-action-rename')), findsNothing);
      expect(find.textContaining('selected'), findsNothing);

      await unmount(tester);
    });
  });

  group('multi-select', () {
    testWidgets('row long-press enters selection: toolbar with count, ⋮ '
        'hidden, tap toggles, × cancels', (tester) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow a = await repo.add('alpha');
      final TodoRow b = await repo.add('beta');
      await settle(tester);
      expect(find.byKey(Key('todo-menu-${a.id}')), findsOneWidget);

      await tester.longPress(find.byKey(Key('todo-row-${a.id}')));
      await settle(tester);

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byKey(TodoListScreen.selectMoveKey), findsOneWidget);
      expect(find.byKey(TodoListScreen.selectDoneKey), findsOneWidget);
      expect(find.byKey(TodoListScreen.selectDeleteKey), findsOneWidget);
      expect(find.byKey(TodoListScreen.selectAllKey), findsOneWidget);
      expect(find.byKey(Key('todo-menu-${a.id}')), findsNothing);
      expect(find.byKey(Key('todo-menu-${b.id}')), findsNothing);

      await tester.tap(find.byKey(Key('todo-row-${b.id}')));
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(Key('todo-row-${b.id}')));
      await settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(TodoListScreen.selectAllKey));
      await settle(tester);
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(TodoListScreen.selectCancelKey));
      await settle(tester);
      expect(find.textContaining('selected'), findsNothing);
      expect(find.byKey(Key('todo-menu-${a.id}')), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('bulk Move files every selected row', (tester) async {
      final TodoRepository repo = await mount(tester);
      final String shop = await db.createFolder(name: 'Shop');
      final TodoRow a = await repo.add('alpha');
      final TodoRow b = await repo.add('beta');
      final TodoRow c = await repo.add('gamma');
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(Key('todo-row-${a.id}')));
      await settle(tester);
      await tester.tap(find.byKey(Key('todo-row-${b.id}')));
      await settle(tester);
      await tester.tap(find.byKey(TodoListScreen.selectMoveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FolderPicker.folderKey(shop)));
      await tester.pumpAndSettle();

      expect((await db.getTodoRow(a.id))!.folderId, shop);
      expect((await db.getTodoRow(b.id))!.folderId, shop);
      expect((await db.getTodoRow(c.id))!.folderId, isNull);
      expect(find.text('Shop (2)'), findsOneWidget);
      expect(find.text('No folder (1)'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing, reason: 'exits');

      await unmount(tester);
    });

    testWidgets('bulk Done checks every selected row', (tester) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow a = await repo.add('alpha');
      final TodoRow b = await repo.add('beta');
      final TodoRow c = await repo.add('gamma');
      await settle(tester);

      await tester.longPress(find.byKey(Key('todo-row-${a.id}')));
      await settle(tester);
      await tester.tap(find.byKey(Key('todo-row-${b.id}')));
      await settle(tester);
      await tester.tap(find.byKey(TodoListScreen.selectDoneKey));
      await settle(tester);

      expect((await db.getTodoRow(a.id))!.doneAt, isNotNull);
      expect((await db.getTodoRow(b.id))!.doneAt, isNotNull);
      expect((await db.getTodoRow(c.id))!.doneAt, isNull);
      expect(find.text('Done (2)'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);

      await unmount(tester);
    });

    testWidgets('bulk Delete confirms ONCE, soft-deletes the set, and one '
        'Undo restores all of them', (tester) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow a = await repo.add('alpha');
      final TodoRow b = await repo.add('beta');
      final TodoRow c = await repo.add('gamma');
      await settle(tester);

      await tester.longPress(find.byKey(Key('todo-row-${a.id}')));
      await settle(tester);
      await tester.tap(find.byKey(Key('todo-row-${b.id}')));
      await settle(tester);
      await tester.tap(find.byKey(TodoListScreen.selectDeleteKey));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 to-dos?'), findsOneWidget);
      await tester.tap(find.byKey(TodoListScreen.bulkDeleteConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing, reason: 'confirmed once');
      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsNothing);
      expect(find.text('gamma'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
      expect(
        (await db.getTodoRow(a.id))?.deletedAt,
        isNotNull,
        reason: 'soft: the row survives under deleted_at',
      );
      expect((await db.getTodoRow(b.id))?.deletedAt, isNotNull);
      expect((await db.getTodoRow(c.id))!.deletedAt, isNull);

      await tester.tap(find.text('Undo'));
      await settle(tester);

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect((await db.getTodoRow(a.id))!.deletedAt, isNull);
      expect((await db.getTodoRow(b.id))!.deletedAt, isNull);

      await tester.pump(const Duration(seconds: 6));
      await unmount(tester);
    });

    testWidgets('back cancels selection first instead of leaving the screen',
        (tester) async {
      final TodoRepository repo = await mountPushed(tester);
      final TodoRow a = await repo.add('alpha');
      await settle(tester);
      expect(find.byType(TodoListScreen), findsOneWidget);

      await tester.longPress(find.byKey(Key('todo-row-${a.id}')));
      await settle(tester);
      expect(find.text('1 selected'), findsOneWidget);

      // The system back gesture, exactly as the platform delivers it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byType(TodoListScreen),
        findsOneWidget,
        reason: 'back must exit selection, not the screen',
      );
      expect(find.textContaining('selected'), findsNothing);
      expect(find.byKey(Key('todo-menu-${a.id}')), findsOneWidget);

      // A second back, with nothing selected, leaves as normal.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TodoListScreen), findsNothing);
      expect(find.byKey(const Key('host-open')), findsOneWidget);

      await unmount(tester);
    });
  });
}
