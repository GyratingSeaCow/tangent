// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Instrument Console v2 on the To Do screen:
//  * the rail rides beneath the screen's own app bar with To Do lit and inert;
//  * the global create key appears (the screen never had a local FAB);
//  * section headers — folders AND Done — render as inset cards without
//    losing the header gestures (tap collapses, long-press is the folder
//    menu, never selection);
//  * the list reserves at least 90px of bottom inset for the FAB.
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
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

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
    await tester.pumpAndSettle();
    return TodoRepository(db: db);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// The nearest Material ancestor — the inset card the header sits in.
  Material cardOf(WidgetTester tester, Finder header) => tester.widget<Material>(
        find.ancestor(of: header, matching: find.byType(Material)).first,
      );

  void expectInsetCard(WidgetTester tester, Finder header) {
    final Material card = cardOf(tester, header);
    final RoundedRectangleBorder shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(TangentShapes.panelRadius));
    expect(shape.side.color, TangentColors.edge);
    expect(shape.side.width, TangentShapes.edgeWidth);
    expect(card.color, TangentColors.panel);
  }

  testWidgets(
      'the rail rides beneath the To Do app bar, lit and inert, with the '
      'global create key', (tester) async {
    await mount(tester);

    final Finder active = find.byKey(railKey(TangentRoot.todo));
    expect(active, findsOneWidget);
    expect(
      tester.widget<IconButton>(active).onPressed,
      isNull,
      reason: 'the active destination is lit, not a navigation target',
    );
    expect(
      // Mockup order: app bar first, rail beneath it.
      tester.getTopLeft(find.byType(TopNavRail)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('To Do')).dy),
    );
    expect(find.byKey(InstrumentScaffold.createFabKey), findsOneWidget);
    // The quick-add stays pinned at top, under the app bar.
    expect(find.byKey(TodoListScreen.quickAddFieldKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets(
      'folder and Done headers are inset cards; tap still collapses and '
      'long-press is still the folder menu', (tester) async {
    final TodoRepository repo = await mount(tester);
    final String folderId = await db.createFolder(name: 'Work');
    final TodoRow filed = await repo.add('filed item');
    await repo.moveToFolder(filed.id, folderId);
    final TodoRow done = await repo.add('done item');
    await repo.toggle(done.id);
    await tester.pumpAndSettle();

    final Finder folderHeader =
        find.byKey(TodoListScreen.folderHeaderKey(folderId));
    expect(folderHeader, findsOneWidget);
    expectInsetCard(tester, folderHeader);
    expectInsetCard(tester, find.byKey(TodoListScreen.doneHeaderKey));
    // Inset from the screen edge, while rows span full width.
    expect(tester.getTopLeft(folderHeader).dx, 10);
    expect(
      tester.getTopLeft(find.byKey(Key('todo-row-${filed.id}'))).dx,
      0,
    );

    // Tap still collapses the section.
    expect(find.text('filed item'), findsOneWidget);
    await tester.tap(folderHeader);
    await tester.pumpAndSettle();
    expect(find.text('filed item'), findsNothing);
    await tester.tap(folderHeader);
    await tester.pumpAndSettle();
    expect(find.text('filed item'), findsOneWidget);

    // Long-press is the folder menu — never selection.
    await tester.longPress(folderHeader);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-action-rename')),
      findsOneWidget,
    );
    expect(find.textContaining('selected'), findsNothing);
    expect(tester.takeException(), isNull);

    // Dismiss the sheet before teardown.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets(
      'the list reserves at least 90px of bottom inset after scrolling to '
      'the end', (tester) async {
    final TodoRepository repo = await mount(tester);
    for (int i = 0; i < 40; i++) {
      await repo.add('item $i');
    }
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -8000));
    await tester.pumpAndSettle();

    final double viewportBottom = tester.getRect(find.byType(Scaffold)).bottom;
    // The visually-last row regardless of section ordering.
    double lastRowBottom = 0;
    for (final Element e in find
        .byWidgetPredicate(
          (Widget w) => w.key != null && '${w.key}'.contains('todo-row-'),
        )
        .evaluate()) {
      final double bottom = tester.getBottomLeft(find.byWidget(e.widget)).dy;
      if (bottom > lastRowBottom) lastRowBottom = bottom;
    }
    expect(lastRowBottom, greaterThan(0), reason: 'rows must be visible');
    expect(
      viewportBottom - lastRowBottom,
      greaterThanOrEqualTo(90),
      reason: 'the FAB and system bar must never cover the last row',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
}
