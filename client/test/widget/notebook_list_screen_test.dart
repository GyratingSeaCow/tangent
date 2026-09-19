// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

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
    List<Folder> folders = const <Folder>[],
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
          foldersProvider.overrideWith(
            (_) => Stream<List<Folder>>.value(folders),
          ),
        ],
        child: const MaterialApp(home: NotebookListScreen()),
      ),
    );
    await tester.pump();
    // The folders StreamProvider needs a frame to deliver its first value;
    // without this the screen groups against an empty folder list.
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

  // Grouping is unit-tested as a pure function; these prove the screen
  // actually renders it. The pure-function tests all passed while the screen
  // was throwing 'Override in main()', so rendering needs its own proof.
  testWidgets('with no folders the list shows no folder headers',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    expect(find.text('Sprint ideas'), findsOneWidget);
    expect(
      find.text('No folder'),
      findsNothing,
      reason: 'a user who never made a folder sees no folder chrome',
    );
    await unmount(tester);
  });

  testWidgets('notebooks appear under their folder header', (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-7', title: 'Sprint ideas', folderId: 'f-work'),
        testNotebook(id: 'nb-8', title: 'Groceries'),
      ],
      folders: <Folder>[
        Folder(id: 'f-work', name: 'Work', createdAt: 1),
      ],
    );

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('No folder'), findsOneWidget);
    expect(find.text('Sprint ideas'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);

    // The filed notebook sits under its header, the loose one under 'No folder'.
    final double workHeaderY = tester.getCenter(find.text('Work')).dy;
    final double filedY = tester.getCenter(find.text('Sprint ideas')).dy;
    final double unfiledHeaderY = tester.getCenter(find.text('No folder')).dy;
    expect(workHeaderY, lessThan(filedY));
    expect(filedY, lessThan(unfiledHeaderY));

    await unmount(tester);
  });

  testWidgets('an empty folder still shows so it can be filed into',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-8', title: 'Groceries')],
      folders: <Folder>[
        Folder(id: 'f-work', name: 'Work', createdAt: 1),
      ],
    );

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
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

  testWidgets('a view toggle switches the list to a cover grid',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-1', title: 'Ideas'),
        testNotebook(id: 'nb-2', title: 'Journal'),
      ],
    );

    // List view is the default, so an existing user's screen is unchanged.
    expect(find.byKey(const ValueKey('notebook-row-nb-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('notebook-cover-nb-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-cover-nb-1')),
      findsOneWidget,
      reason: 'the toggle must switch to covers, like Samsung Notes book view',
    );
    expect(
      find.byKey(const ValueKey('notebook-row-nb-1')),
      findsNothing,
      reason: 'one view at a time; both at once would duplicate every item',
    );
    expect(
      find.text('Ideas'),
      findsOneWidget,
      reason: 'a cover still names its notebook -- an unlabelled grid of '
          'identical covers cannot be navigated',
    );

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notebook-row-nb-1')), findsOneWidget);
  });

  testWidgets('covers keep their folder sections', (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        testNotebook(id: 'nb-2', title: 'Loose'),
      ],
      folders: <Folder>[
        Folder(id: 'f-1', name: 'Work', createdAt: 1),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-section-f-1')),
      findsOneWidget,
      reason: 'filing must survive the view change, or covers lose folders',
    );
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('a cover opens and offers the same actions as a row',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Ideas')],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('notebook-cover-nb-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'the menu must not disappear just because the view changed',
    );
  });

  testWidgets('the view choice survives a restart', (tester) async {
    // A toggle that forgets is worse than no toggle. Two things must hold, and
    // the earlier version of this test asserted neither: the choice is WRITTEN
    // to storage, and a COLD start reads it back. Remounting alone proves
    // nothing, because the widget keeps showing covers from its own in-memory
    // field whether or not anything was persisted -- a sabotage that deleted
    // both the write and the read still passed.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Ideas')],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notebook-cover-nb-1')), findsOneWidget);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('notebooks.coverView'),
      isTrue,
      reason: 'the choice must be written, not just held in memory',
    );

    // A cold start: tear the widget down entirely, then mount a fresh screen
    // against the stored value.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Ideas')],
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-cover-nb-1')),
      findsOneWidget,
      reason: 'a fresh screen must restore the stored view',
    );
  });

  testWidgets('a fresh install opens in list view', (tester) async {
    // The default must not drift: an existing user who never asked for covers
    // should see exactly the screen they had.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Ideas')],
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notebook-row-nb-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('notebook-cover-nb-1')), findsNothing);
  });

  testWidgets('a stored cover preference opens in cover view',
      (tester) async {
    // The read path, proved independently of the write path.
    SharedPreferences.setMockInitialValues(
      <String, Object>{'notebooks.coverView': true},
    );
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Ideas')],
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-cover-nb-1')),
      findsOneWidget,
      reason: 'a stored preference must be honoured on first build',
    );
  });

  testWidgets('tapping a folder header collapses only that section (list)',
      (tester) async {
    // Folder names are tap targets: collapse hides the folder's notebooks so
    // a long library can be skimmed. Other sections must not move state.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        testNotebook(id: 'nb-2', title: 'Also filed', folderId: 'f-2'),
      ],
      folders: <Folder>[
        Folder(id: 'f-1', name: 'Work', createdAt: 1),
        Folder(id: 'f-2', name: 'Home', createdAt: 2),
      ],
    );

    expect(find.byKey(const ValueKey('notebook-row-nb-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notebook-section-f-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-row-nb-1')),
      findsNothing,
      reason: 'a collapsed folder hides its notebooks',
    );
    expect(
      find.byKey(const ValueKey('notebook-row-nb-2')),
      findsOneWidget,
      reason: "collapsing one folder must not touch another's rows",
    );
    expect(
      find.text('Work'),
      findsOneWidget,
      reason: 'the header itself stays visible, or it cannot be re-expanded',
    );

    await tester.tap(find.byKey(const ValueKey('notebook-section-f-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-row-nb-1')),
      findsOneWidget,
      reason: 'a second tap restores the section',
    );

    await unmount(tester);
  });

  testWidgets('folder collapse works identically in the cover view',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        testNotebook(id: 'nb-2', title: 'Loose'),
      ],
      folders: <Folder>[
        Folder(id: 'f-1', name: 'Work', createdAt: 1),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notebook-cover-nb-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notebook-section-f-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-cover-nb-1')),
      findsNothing,
      reason: 'the alternate view must collapse too, or the feature is a lie '
          'for cover users',
    );
    expect(
      find.byKey(const ValueKey('notebook-cover-nb-2')),
      findsOneWidget,
      reason: 'the unfiled section is untouched by another folder collapsing',
    );

    await tester.tap(find.byKey(const ValueKey('notebook-section-f-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notebook-cover-nb-1')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('collapse state survives switching views', (tester) async {
    // The two views are one library. A folder collapsed in the list arriving
    // expanded in covers would read as the toggle losing the user's place.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await mountList(
      tester,
      seed: <Notebook>[
        testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
      ],
      folders: <Folder>[
        Folder(id: 'f-1', name: 'Work', createdAt: 1),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-section-f-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notebook-row-nb-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notebook-view-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-cover-nb-1')),
      findsNothing,
      reason: 'the collapse must carry across the view toggle',
    );

    await unmount(tester);
  });
}
