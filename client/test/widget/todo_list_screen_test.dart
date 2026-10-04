// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/screens/home/home_providers.dart'
    show documentSyncEngineProvider;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesClientProvider;
import 'package:tangent/screens/todo/todo_list_screen.dart';
import 'package:tangent/services/summaries_client.dart';
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
  syncButtonTests();

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
      final TextField field = tester.widget(
        find.byKey(TodoListScreen.quickAddFieldKey),
      );
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

  testWidgets('a pin is visible and the row action unpins it', (tester) async {
    final TodoRepository repo = await mount(tester);
    final TodoRow todo = await repo.add('Pinned task');
    await repo.setPinned(todo.id, true);
    await settle(tester);

    expect(find.byKey(Key('todo-pin-${todo.id}')), findsOneWidget);
    await tester.tap(find.byKey(Key('todo-menu-${todo.id}')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.unpin)),
      findsOneWidget,
    );
    expect(find.byKey(ItemActionSheet.keyFor(ItemAction.pin)), findsNothing);

    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.unpin)));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('todo-pin-${todo.id}')), findsNothing);
    expect((await db.getTodoRow(todo.id))!.pinned, isFalse);
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
    final TodoRow overdue = await repo.add(
      'overdue item',
      dueDate: '2026-09-20',
    );
    final TodoRow later = await repo.add('later item', dueDate: '2026-10-03');
    final TodoRow today = await repo.add(
      'today item',
      dueDate: todoDateKey(fixedNow),
    );
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

  testWidgets('tapping the text opens inline edit and submit saves it', (
    tester,
  ) async {
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
    final TodoRow added = await repo.add(
      'dated',
      dueDate: todoDateKey(fixedNow),
    );
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
        'sheet — never selection; No folder and Done have no actions', (
      tester,
    ) async {
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

    testWidgets('back cancels selection first instead of leaving the screen', (
      tester,
    ) async {
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

  group('kanban board', () {
    testWidgets('toggle persists and board seeds the three default columns', (
      tester,
    ) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow todo = await repo.add('board card');
      await settle(tester);

      await tester.tap(find.byKey(TodoListScreen.viewToggleKey));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-board-scroll')), findsOneWidget);
      expect(find.text('To Do (1)'), findsOneWidget);
      expect(find.text('In Progress (0)'), findsOneWidget);
      expect(find.text('Done (0)'), findsOneWidget);
      expect(find.byKey(TodoListScreen.cardKey(todo.id)), findsOneWidget);
      await tester.longPress(find.byKey(TodoListScreen.cardKey(todo.id)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(TodoListScreen.selectCancelKey),
        findsNothing,
        reason: 'board long-press must not enter list multi-select',
      );
      await tester.tap(find.byKey(Key('todo-check-${todo.id}')));
      await tester.pumpAndSettle();
      final TodoRow checked = (await db.getTodoRow(todo.id))!;
      expect(checked.doneAt, isNotNull);
      expect(checked.columnId, defaultTodoColumnId);
      expect(find.byKey(TodoListScreen.cardKey(todo.id)), findsOneWidget);

      await unmount(tester);
      await mount(tester);
      expect(
        find.byKey(const Key('todo-board-scroll')),
        findsOneWidget,
        reason: 'the selected view survives a screen restart',
      );
      await unmount(tester);
    });

    testWidgets('direct drag moves across columns and reorders within a lane', (
      tester,
    ) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow a = await repo.add('alpha');
      final TodoRow b = await repo.add('beta');
      final TodoRow c = await repo.add('gamma');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TodoListScreen.viewToggleKey));
      await tester.pumpAndSettle();
      final String progress = (await repo.listColumns())[1].id;

      await tester.drag(
        find.byKey(TodoListScreen.cardKey(b.id)),
        tester.getCenter(find.byKey(TodoListScreen.dropKey(progress, 0))) -
            tester.getCenter(find.byKey(TodoListScreen.cardKey(b.id))),
      );
      await tester.pumpAndSettle();
      expect((await db.getTodoRow(b.id))!.columnId, progress);

      await tester.drag(
        find.byKey(TodoListScreen.cardKey(c.id)),
        tester.getCenter(
              find.byKey(TodoListScreen.dropKey(defaultTodoColumnId, 0)),
            ) -
            tester.getCenter(find.byKey(TodoListScreen.cardKey(c.id))),
      );
      await tester.pumpAndSettle();
      final List<TodoRow> lane =
          (await repo.listTodos())
              .where((row) => row.columnId == defaultTodoColumnId)
              .toList()
            ..sort((x, y) => x.boardOrder.compareTo(y.boardOrder));
      expect(lane.map((row) => row.id), <String>[c.id, a.id]);
      await unmount(tester);
    });

    testWidgets(
      'non-empty delete prompts for destination and keeps every card',
        (tester) async {
        final TodoRepository repo = await mount(tester);
        final TodoRow card = await repo.add('must survive');
        final List<TodoColumnRow> columns = await repo.listColumns();
        final TodoColumnRow progress = columns[1];
        final TodoColumnRow done = columns[2];
        await repo.moveOnBoard(card.id, progress.id, 0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TodoListScreen.viewToggleKey));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(TodoListScreen.columnMenuKey(progress.id)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(find.text('Move 1 card to:'), findsOneWidget);
        await tester.tap(find.text(done.name).last);
        await tester.pumpAndSettle();

        final TodoRow kept = (await db.getTodoRow(card.id))!;
        expect(kept.columnId, done.id);
        expect(kept.deletedAt, isNull);
        expect(find.text('must survive'), findsOneWidget);
        expect(find.byKey(TodoListScreen.columnKey(progress.id)), findsNothing);
        await unmount(tester);
      },
    );

    testWidgets(
      'columns can be added, renamed, and reordered from their menu',
      (tester) async {
        await mount(tester);
        await tester.tap(find.byKey(TodoListScreen.viewToggleKey));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(TodoListScreen.addColumnKey));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(TodoListScreen.columnNameFieldKey),
          'Waiting',
        );
        await tester.tap(find.byKey(TodoListScreen.columnSaveKey));
        await tester.pumpAndSettle();
        TodoColumnRow waiting = (await TodoRepository(
          db: db,
        ).listColumns()).singleWhere((column) => column.name == 'Waiting');

        await tester.drag(
          find.byKey(const Key('todo-board-scroll')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TodoListScreen.columnMenuKey(waiting.id)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(TodoListScreen.columnNameFieldKey),
          'Blocked',
        );
        await tester.tap(find.byKey(TodoListScreen.columnSaveKey));
        await tester.pumpAndSettle();
        waiting = (await TodoRepository(
          db: db,
        ).listColumns()).singleWhere((column) => column.id == waiting.id);
        expect(waiting.name, 'Blocked');

        await tester.drag(
          find.byKey(const Key('todo-board-scroll')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TodoListScreen.columnMenuKey(waiting.id)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move left'));
        await tester.pumpAndSettle();
        expect((await TodoRepository(db: db).listColumns())[2].id, waiting.id);
        await unmount(tester);
      },
    );
  });

  group('google chip', () {
    testWidgets('a "G" chip marks ONLY rows whose source is google', (
      tester,
    ) async {
      final TodoRepository repo = await mount(tester);
      final TodoRow manual = await repo.add('Buy milk');
      final TodoRow voice = await repo.add(
        'Call Sam',
        source: 'voice',
        sourceRef: 'dump-1',
      );
      final TodoRow google = await repo.add(
        'Renew passport',
        source: 'google',
        sourceRef: 'gt-1',
      );
      await settle(tester);

      expect(find.byKey(Key('todo-row-${manual.id}')), findsOneWidget);
      expect(find.byKey(Key('todo-row-${voice.id}')), findsOneWidget);
      expect(find.byKey(Key('todo-row-${google.id}')), findsOneWidget);

      expect(find.byKey(Key('todo-google-chip-${google.id}')), findsOneWidget);
      expect(find.byKey(Key('todo-google-chip-${manual.id}')), findsNothing);
      expect(find.byKey(Key('todo-google-chip-${voice.id}')), findsNothing);
      await unmount(tester);
    });
  });
}

// --- v1.29.0: manual sync on the To Do page ---------------------------------

/// A client that records what the engine asked it to do, so the test can
/// prove the To Do button drives a REAL sync cycle (pull, then push of the
/// dirty to-do) and not just an icon.
/// Records the ORDER of every call across the device sync and the Google
/// follow-up. Shared by the two fakes below so the ordering test can assert
/// "push, then Google" in one list rather than two counters.
final List<String> _callLog = <String>[];

/// A [SummariesClient] whose Google Tasks verbs are scripted. It never opens
/// a socket: `baseUrl` is a non-routable placeholder and every method the
/// screen touches is overridden.
class _FakeGoogleClient extends SummariesClient {
  _FakeGoogleClient({required this.status, this.syncError, this.syncNowThrows})
    : super(baseUrl: 'http://unused.invalid');

  final String status;
  final String? syncError;
  final Object? syncNowThrows;
  int statusCalls = 0;
  int syncNowCalls = 0;

  @override
  Future<GoogleTasksStatus> getGoogleTasksStatus() async {
    statusCalls++;
    _callLog.add('google-status');
    return GoogleTasksStatus.fromJson(<String, dynamic>{'status': status});
  }

  @override
  Future<GoogleTasksStatus> syncGoogleTasksNow() async {
    syncNowCalls++;
    _callLog.add('google-sync-now');
    final Object? err = syncNowThrows;
    if (err != null) throw err;
    return GoogleTasksStatus.fromJson(<String, dynamic>{
      'status': syncError == null ? 'connected' : 'error',
      'last_error': syncError,
      'pushed': 1,
    });
  }
}

class _RecordingSyncClient implements TranscriptionClient {
  int pulls = 0;
  List<Map<String, dynamic>> pushed = <Map<String, dynamic>>[];

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {}

  @override
  Future<SyncPullPage> pullChanges({
    required String deviceId,
    required int sinceSeq,
  }) async {
    pulls++;
    _callLog.add('device-pull');
    return SyncPullPage(changes: const [], headSeq: sinceSeq, hasMore: false);
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async {
    pushed.addAll(changes);
    _callLog.add('device-push');
    return <PushResult>[
      for (final Map<String, dynamic> c in changes)
        PushResult(
          entityType: c['entity_type'] as String,
          entityId: c['entity_id'] as String,
          applied: true,
          seq: 1,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _WifiConnectivity implements ConnectivityService {
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.wifi;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void syncButtonTests() {
  group('To Do sync button (v1.29.0)', () {
    testWidgets('the app bar has the shared sync button and a tap pulls, '
        'then pushes the dirty to-do', (tester) async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final _RecordingSyncClient client = _RecordingSyncClient();
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _WifiConnectivity(),
        deviceLabel: () async => 'test-device',
        newDeviceId: 'device-1',
      );
      addTearDown(engine.dispose);
      await TodoRepository(db: db).add('buy thermal paste');

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            localDbProvider.overrideWithValue(db),
            documentSyncEngineProvider.overrideWithValue(engine),
            // Google not linked: the v1.30.0 follow-up must leave this
            // message exactly as it was in v1.29.0.
            summariesClientProvider.overrideWith(
              (ref) => Future<SummariesClient>.value(
                _FakeGoogleClient(status: 'disconnected'),
              ),
            ),
          ],
          child: const MaterialApp(home: TodoListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final Finder button = find.byKey(const ValueKey<String>('sync-button'));
      expect(button, findsOneWidget, reason: 'To Do must own a sync button');
      expect(client.pulls, 0, reason: 'nothing runs until the tap');

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(client.pulls, 1);
      expect(
        client.pushed.map((c) => c['entity_type']),
        contains('todo'),
        reason: 'the dirty to-do travels in the same press',
      );
      expect(find.text('Synced: sent 4'), findsOneWidget);
      // The snackbar's dismiss timer outlives the test otherwise.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });

  group('To Do sync button → Google (v1.30.0, L4)', () {
    /// Mounts To Do over a fake device-sync client and a scripted Google
    /// client, taps ↻, and returns both fakes for assertions.
    Future<(_RecordingSyncClient, _FakeGoogleClient)> tapSync(
      WidgetTester tester, {
      required _FakeGoogleClient google,
    }) async {
      _callLog.clear();
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final _RecordingSyncClient client = _RecordingSyncClient();
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _WifiConnectivity(),
        deviceLabel: () async => 'test-device',
        newDeviceId: 'device-1',
      );
      addTearDown(engine.dispose);
      await TodoRepository(db: db).add('buy thermal paste');

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            localDbProvider.overrideWithValue(db),
            documentSyncEngineProvider.overrideWithValue(engine),
            summariesClientProvider.overrideWith(
              (ref) => Future<SummariesClient>.value(google),
            ),
          ],
          child: const MaterialApp(home: TodoListScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(google.syncNowCalls, 0, reason: 'nothing runs until the tap');

      await tester.tap(find.byKey(const ValueKey<String>('sync-button')));
      await tester.pumpAndSettle();
      return (client, google);
    }

    /// The snackbar's dismiss timer outlives the test otherwise; the widget
    /// tree must be gone before the framework checks for pending timers, so
    /// this runs INSIDE the body, not in a tearDown.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets(
        'connected: one Google cycle runs AFTER the device push and the '
      'snackbar says so',
      (tester) async {
        final (
          _RecordingSyncClient client,
          _FakeGoogleClient google,
        ) = await tapSync(
          tester,
          google: _FakeGoogleClient(status: 'connected'),
        );

      expect(client.pulls, 1);
      expect(google.syncNowCalls, 1, reason: 'exactly one Google cycle');
      // The whole point of L4: Google must receive the state the server has
      // AFTER this press. A hook that ran first would forward the stale row.
        expect(_callLog, <String>[
          'device-pull',
          'device-push',
          'google-status',
          'google-sync-now',
        ], reason: 'device sync completes before any Google call');
        expect(find.text('Synced: sent 4 · Google updated'), findsOneWidget);
      await unmount(tester);
      },
    );

    testWidgets('not connected: no Google call, message unchanged', (
      tester,
    ) async {
      final (_, _FakeGoogleClient google) = await tapSync(
        tester,
        google: _FakeGoogleClient(status: 'disconnected'),
      );

      expect(google.statusCalls, 1, reason: 'the status IS consulted');
      expect(google.syncNowCalls, 0, reason: 'but nothing is pushed');
      expect(find.text('Synced: sent 4'), findsOneWidget);
      expect(find.textContaining('Google'), findsNothing);
      await unmount(tester);
    });

    testWidgets('reauth_required counts as not connected', (tester) async {
      final (_, _FakeGoogleClient google) = await tapSync(
        tester,
        google: _FakeGoogleClient(status: 'reauth_required'),
      );
      expect(google.syncNowCalls, 0);
      expect(find.text('Synced: sent 4'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the cycle ran but Google reported an error: named', (
      tester,
    ) async {
      await tapSync(
        tester,
        google: _FakeGoogleClient(
          status: 'connected',
          syncError: 'HTTP 503 from tasks.googleapis.com',
        ),
      );
      expect(
        find.text(
          'Synced: sent 4 · Google: HTTP 503 from tasks.googleapis.com',
        ),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('the Google call throws: the device sync is still reported', (
      tester,
    ) async {
      await tapSync(
        tester,
        google: _FakeGoogleClient(
          status: 'connected',
          syncNowThrows: const ApiException(
            statusCode: 502,
            code: 'upstream',
            message: 'Google unreachable',
          ),
        ),
      );
      // The device sync DID succeed; the follow-up's failure is appended,
      // never allowed to swallow the sentence or crash the button.
      expect(
        find.text('Synced: sent 4 · Google: Google unreachable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  });
}
