// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/todo/todo_list_screen.dart';
import 'package:tangent/services/todo_voice_capture.dart';
import 'package:tangent/widgets/voice_todos_card.dart';

/// To Do arc Phase 2 (V3): the "Added to your To Do list" card on the
/// recording detail screen — what it lists, what Undo does to it, and the
/// fact that it is absent when the recording produced nothing.
void main() {
  late LocalDb db;
  late TodoRepository repo;
  int ids = 0;

  const String dumpId = 'dump-1';

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    ids = 0;
    repo = TodoRepository(
      db: db,
      idFactory: () => 'todo-${++ids}',
      now: () => DateTime.utc(2026, 9, 27, 12),
    );
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          todoRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VoiceTodosCard(dumpId: dumpId),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Future<void> capture([String? transcript]) => captureVoiceTodos(
        db: db,
        dumpId: dumpId,
        transcript: transcript ??
            'add to my to do list pick up thermal paste and email the '
                'Zionsville customer back',
        recordedOn: DateTime(2026, 9, 27),
        repository: repo,
      );

  testWidgets('the card lists exactly the added items', (tester) async {
    await capture();
    await mount(tester);

    expect(find.text('Added to your To Do list'), findsOneWidget);
    expect(find.text('pick up thermal paste'), findsOneWidget);
    expect(find.text('email the Zionsville customer back'), findsOneWidget);
    // A plain bulleted list: text only, no checkboxes in this card.
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('•  '), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('no card when the recording produced no voice todos',
      (tester) async {
    await capture('just thinking out loud, nothing actionable');
    await mount(tester);

    expect(find.text('Added to your To Do list'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('voice-todos-card-$dumpId')),
      findsNothing,
    );
    expect(find.text('Undo'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a manual todo retaining dump provenance does not summon the card',
      (tester) async {
    final TodoRow manual = await repo.add(
      'typed by hand',
      sourceRef: dumpId,
    );
    await mount(tester);

    expect(find.text('Added to your To Do list'), findsNothing);
    expect(find.text('typed by hand'), findsNothing);
    expect(manual.source, 'manual');
    expect(manual.sourceRef, dumpId, reason: 'tap-through provenance survives');

    await unmount(tester);
  });

  testWidgets('Undo soft-deletes this dump\'s items, hides the card, and '
      'confirms with a snackbar', (tester) async {
    final TodoRow manual = await repo.add(
      'manual card on the same dump',
      sourceRef: dumpId,
    );
    await capture();
    await mount(tester);
    expect(find.text('pick up thermal paste'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('voice-todos-undo-$dumpId')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Card gone, items gone from the live list...
    expect(find.text('Added to your To Do list'), findsNothing);
    expect(find.text('pick up thermal paste'), findsNothing);
    expect(find.text('Removed 2 to-dos'), findsOneWidget);
    // ...but the rows survive as tombstoned provenance, which is what keeps
    // a re-sync from resurrecting them.
    final List<TodoRow> rows = await repo.todosFromSource(dumpId);
    expect(rows.length, 2);
    expect(rows.every((r) => r.deletedAt != null), isTrue);
    final TodoRow survivingManual = (await db.getTodoRow(manual.id))!;
    expect(survivingManual.deletedAt, isNull);
    expect(survivingManual.source, 'manual');
    expect(survivingManual.sourceRef, dumpId);
    expect(await repo.hasTodosFromSource(dumpId), isTrue);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('tapping the card body opens the To Do screen', (tester) async {
    await capture();
    await mount(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('voice-todos-open-$dumpId')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TodoListScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
}
