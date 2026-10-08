// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

DumpRow _transcribed(String id, String transcript) => viewRow(id).copyWith(
  transcript: Value<String?>(transcript),
  transcriptionStatus: 'completed',
);

void main() {
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<({LocalDb db, TodoRepository repo})> mountRows(
    WidgetTester tester,
    List<DumpRow> rows,
  ) async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[localDbProvider.overrideWithValue(db)],
    );
    container.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'all',
      generation: 2,
      settled: true,
      rows: rows,
      limit: null,
    ));
    await pumpSelection(tester);
    return (db: db, repo: TodoRepository(db: db));
  }

  Future<void> chooseTodoAction(WidgetTester tester) async {
    final Finder action = find.byKey(
      ItemActionSheet.keyFor(ItemAction.sendToTodo),
    );
    await tester.ensureVisible(action);
    await tester.tap(action);
    await pumpSelection(tester);
  }

  testWidgets('long press and three dots share the Add to To-Do action gate', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    await mountRows(tester, <DumpRow>[
      _transcribed('ready', 'ready transcript'),
      viewRow('waiting'),
    ]);
    final Finder action = find.byKey(
      ItemActionSheet.keyFor(ItemAction.sendToTodo),
    );

    await tester.tap(find.byKey(const ValueKey<String>('dump-more-ready')));
    await pumpSelection(tester);
    expect(action, findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    expect(find.text('Add to To-Do…'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await pumpSelection(tester);

    await tester.longPress(
      find.byKey(const ValueKey<String>('dump-row-ready')),
    );
    await pumpSelection(tester);
    expect(action, findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    await tester.tapAt(const Offset(8, 8));
    await pumpSelection(tester);

    await tester.tap(find.byKey(const ValueKey<String>('dump-more-waiting')));
    await pumpSelection(tester);
    expect(action, findsOneWidget, reason: 'ineligible actions stay visible');
    expect(tester.widget<ListTile>(action).enabled, isFalse);
    expect(find.text('No transcript yet'), findsOneWidget);
  });

  testWidgets(
    'single add edits verbatim text and appends with dump provenance',
    (WidgetTester tester) async {
      tallView(tester);
      final ({LocalDb db, TodoRepository repo}) fixture = await mountRows(
        tester,
        <DumpRow>[_transcribed('single', 'original\ntranscript')],
      );
      final List<TodoColumnRow> columns = await fixture.repo.ensureColumns();
      final TodoRow anchor = await fixture.repo.add('existing card');
      await fixture.repo.moveOnBoard(anchor.id, columns[1].id, 0);

      await tester.tap(find.byKey(const ValueKey<String>('dump-more-single')));
      await pumpSelection(tester);
      await chooseTodoAction(tester);
      await tester.tap(
        find.byKey(ValueKey<String>('todo-column-picker-${columns[1].id}')),
      );
      await pumpSelection(tester);

      final Finder field = find.byKey(
        const ValueKey<String>('todo-transcript-field'),
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'original\ntranscript',
      );
      const String edited = '  edited first line\nsecond line  ';
      await tester.enterText(field, edited);
      await tester.tap(
        find.byKey(const ValueKey<String>('todo-transcript-add')),
      );
      await pumpSelection(tester);

      final List<TodoRow> created = await fixture.repo.todosFromSource(
        'single',
      );
      expect(created, hasLength(1));
      expect(created.single.body, edited);
      expect(created.single.columnId, columns[1].id);
      expect(created.single.boardOrder, 1);
      expect(created.single.sourceRef, 'single');
      expect(created.single.source, 'manual');
      expect(created.single.syncDirty, isTrue);
    },
  );

  testWidgets('canceling the single transcript editor creates no card', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final ({LocalDb db, TodoRepository repo}) fixture = await mountRows(
      tester,
      <DumpRow>[_transcribed('cancel-me', 'do not add')],
    );
    final List<TodoColumnRow> columns = await fixture.repo.ensureColumns();

    await tester.tap(find.byKey(const ValueKey<String>('dump-more-cancel-me')));
    await pumpSelection(tester);
    await chooseTodoAction(tester);
    await tester.tap(
      find.byKey(ValueKey<String>('todo-column-picker-${columns.first.id}')),
    );
    await pumpSelection(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('todo-transcript-cancel')),
    );
    await pumpSelection(tester);

    expect(await fixture.repo.todosFromSource('cancel-me'), isEmpty);
  });

  testWidgets(
    'bulk add skips missing transcripts and preserves selection order',
    (WidgetTester tester) async {
      tallView(tester);
      final ({LocalDb db, TodoRepository repo}) fixture =
          await mountRows(tester, <DumpRow>[
            _transcribed('first', ' first verbatim\n'),
            viewRow('missing'),
            _transcribed('last', 'last verbatim'),
          ]);
      final List<TodoColumnRow> columns = await fixture.repo.ensureColumns();
      final TodoRow anchor = await fixture.repo.add('existing card');
      await fixture.repo.moveOnBoard(anchor.id, columns[1].id, 0);

      await tester.longPress(
        find.byKey(const ValueKey<String>('dump-row-missing')),
      );
      await pumpSelection(tester);
      final Finder select = find.byKey(
        ItemActionSheet.keyFor(ItemAction.select),
      );
      await tester.ensureVisible(select);
      await tester.tap(select);
      await pumpSelection(tester);
      final IconButton onlyMissing = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('selection-send-to-todo')),
      );
      expect(onlyMissing.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey<String>('dump-select-first')));
      await tester.tap(find.byKey(const ValueKey<String>('dump-select-last')));
      await pumpSelection(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('selection-send-to-todo')),
      );
      await pumpSelection(tester);
      await tester.tap(
        find.byKey(ValueKey<String>('todo-column-picker-${columns[1].id}')),
      );
      await pumpSelection(tester);

      final List<TodoRow> lane =
          (await fixture.repo.listTodos())
              .where((TodoRow row) => row.columnId == columns[1].id)
              .toList()
            ..sort(
              (TodoRow a, TodoRow b) => a.boardOrder.compareTo(b.boardOrder),
            );
      expect(lane.map((TodoRow row) => row.body), <String>[
        'existing card',
        ' first verbatim\n',
        'last verbatim',
      ]);
      expect(lane.skip(1).map((TodoRow row) => row.sourceRef), <String>[
        'first',
        'last',
      ]);
      expect(
        find.text('Added 2 to To-Do — 1 skipped (no transcript)'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('selection-all')), findsNothing);
    },
  );
}
