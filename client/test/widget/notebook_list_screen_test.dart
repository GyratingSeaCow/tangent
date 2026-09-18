// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';

import '../support/fake_notebook_repository.dart';

/// T4: the notebook list — live rows from [notebooksProvider], tap to edit,
/// a `+` FAB that creates AND immediately opens a notebook, and a confirmed
/// delete that never fires without the user saying so.

/// Forwards to the fake repository so tests still observe deletes, while the
/// screen exercises the real durable-publication seam (row + file), not the
/// bare repository — the device found the editor and list wired to the wrong
/// one, leaving orphan files in 'Tangent Notebooks'.
class _ForwardingNotebookPersistence implements NotebookPersistence {
  _ForwardingNotebookPersistence(this._repository);

  final NotebookRepository _repository;

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    return notebook;
  }

  @override
  Future<ComponentResult> deleteNotebook(String id) async {
    await _repository.deleteNotebook(id);
    return (state: ComponentState.removed, problem: null);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository repository;

  Future<void> mountList(
    WidgetTester tester, {
    List<Notebook> seed = const <Notebook>[],
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    repository = FakeNotebookRepository(seed: seed);
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          notebookRepositoryProvider.overrideWithValue(repository),
          notebookPersistenceProvider.overrideWithValue(
            _ForwardingNotebookPersistence(repository),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
        ],
        child: const MaterialApp(home: NotebookListScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('renders the notebooks the provider emits, newest first',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(
          id: 'nb-old',
          title: 'Groceries',
          updatedAt: DateTime.utc(2026, 9, 10, 8),
        ),
        testNotebook(
          id: 'nb-new',
          title: 'Sprint ideas',
          updatedAt: DateTime.utc(2026, 9, 17, 9),
        ),
      ],
    );

    expect(find.text('Sprint ideas'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Sprint ideas')).dy <
          tester.getTopLeft(find.text('Groceries')).dy,
      isTrue,
      reason: 'the list follows the provider order (updated_at DESC)',
    );
    expect(find.text('No notebooks yet'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('an empty library reads "No notebooks yet"', (tester) async {
    await mountList(tester);

    expect(find.text('No notebooks yet'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('the FAB creates a notebook and opens its editor',
      (tester) async {
    await mountList(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.createCalls, 1);
    expect(find.byType(NotebookEditorScreen), findsOneWidget);
    expect(
      tester.widget<NotebookEditorScreen>(find.byType(NotebookEditorScreen))
          .notebookId,
      'notebook-1',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('tapping a row opens that notebook in the editor',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    await tester.tap(find.text('Sprint ideas'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.createCalls, 0);
    expect(
      tester.widget<NotebookEditorScreen>(find.byType(NotebookEditorScreen))
          .notebookId,
      'nb-7',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('delete asks for confirmation and cancelling deletes nothing',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-menu-nb-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('item-action-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Delete notebook?'), findsOneWidget);
    expect(repository.deleted, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(repository.deleted, isEmpty);
    expect(find.text('Sprint ideas'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('confirming the dialog deletes the notebook', (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-7', title: 'Sprint ideas'),
        testNotebook(
          id: 'nb-8',
          title: 'Groceries',
          updatedAt: DateTime.utc(2026, 9, 10),
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-menu-nb-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('item-action-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(repository.deleted, <String>['nb-7']);
    expect(find.text('Sprint ideas'), findsNothing);
    expect(find.text('Groceries'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  // The behaviour change: long-press used to delete outright. It now opens the
  // shared menu, so the destructive path always has a menu in front of it and
  // the gesture means the same thing as it does on every other list.
  testWidgets('long-press opens the action menu instead of deleting',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('item-action-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('item-action-delete')), findsOneWidget);
    expect(
      find.text('Delete notebook?'),
      findsNothing,
      reason: 'long-press must not jump straight to the destructive dialog',
    );
    expect(repository.deleted, isEmpty);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('rename from the menu saves the new title', (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('item-action-rename')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.byKey(const ValueKey('notebook-rename-field')),
      'Q4 planning',
    );
    await tester.tap(find.byKey(const ValueKey('notebook-rename-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      repository.saved.map((Notebook n) => n.title),
      contains('Q4 planning'),
      reason: 'rename must persist through the notebook persistence layer',
    );
    expect(repository.deleted, isEmpty);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
}
