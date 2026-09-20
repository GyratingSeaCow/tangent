// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
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

/// Live-folder fake for the header-action tests. A REAL drift db in a
/// widget test trips '!timersPending' (StreamQueryStore closes queries via
/// a zero-duration timer), which is why this suite fakes persistence
/// everywhere; folder DELETE semantics (unfiling notebooks + dumps, the
/// sync tombstone) are covered at the db layer in dump_folders_test and
/// folders_schema_test.
class _FakeFoldersDb implements LocalDb {
  final List<Folder> _folders = <Folder>[];
  final StreamController<List<Folder>> _stream =
      StreamController<List<Folder>>.broadcast();
  final List<String> deletedFolderIds = <String>[];

  void seedFolder(Folder folder) {
    _folders.add(folder);
  }

  void _emit() => _stream.add(List<Folder>.from(_folders));

  @override
  Stream<List<Folder>> watchFolders() async* {
    yield List<Folder>.from(_folders);
    yield* _stream.stream;
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    _folders.removeWhere((Folder f) => f.id == folderId);
    deletedFolderIds.add(folderId);
    _emit();
  }

  @override
  Future<void> renameFolder({
    required String folderId,
    required String name,
  }) async {
    final int i = _folders.indexWhere((Folder f) => f.id == folderId);
    if (i != -1) {
      _folders[i] = Folder(
        id: _folders[i].id,
        name: name,
        createdAt: _folders[i].createdAt,
      );
    }
    _emit();
  }

  Future<void> dispose() => _stream.close();

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
    _FakeFoldersDb? db,
    NotebookPdfShare? sharePdf,
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
            // The fake streams live folders so deletion is observable;
            // otherwise the static seed list is enough.
            (_) => db?.watchFolders() ?? Stream<List<Folder>>.value(folders),
          ),
          if (db != null) localDbProvider.overrideWithValue(db),
        ],
        child: MaterialApp(
          home: NotebookListScreen(sharePdfOverride: sharePdf),
        ),
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
      tester
          .widget<NotebookEditorScreen>(find.byType(NotebookEditorScreen))
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
      tester
          .widget<NotebookEditorScreen>(find.byType(NotebookEditorScreen))
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

  // The unified contract: long-press means multi-select on every list, the
  // same as dumps. Per-item actions live behind the row's own menu button.
  testWidgets('long-press enters selection instead of opening a menu',
      (tester) async {
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-7', title: 'Sprint ideas')],
    );

    await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey('notebook-selection-cancel')),
      findsOneWidget,
      reason: 'long-press must enter selection mode, as it does on dumps',
    );
    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('item-action-rename')),
      findsNothing,
      reason: 'the per-item menu belongs to the row menu button, not '
          'long-press',
    );
    expect(find.text('Delete notebook?'), findsNothing);
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

    await tester.tap(find.byKey(const ValueKey('notebook-menu-nb-7')));
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

    // Same split as the list: the cover's ⋮ button carries the per-item
    // menu, long-press means multi-select in both views.
    await tester.tap(find.byKey(const ValueKey('notebook-cover-menu-nb-1')));
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

  testWidgets('a stored cover preference opens in cover view', (tester) async {
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

  group('folder header actions', () {
    _FakeFoldersDb mkDb({String name = 'Work'}) {
      // Collapse state persists in the SharedPreferences mock across tests
      // in this file; a folder left collapsed by an earlier test hides the
      // rows this group asserts on.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _FakeFoldersDb db = _FakeFoldersDb()
        ..seedFolder(Folder(id: 'f-1', name: name, createdAt: 1));
      addTearDown(db.dispose);
      return db;
    }

    testWidgets('long-pressing a folder header offers rename and delete',
        (tester) async {
      final _FakeFoldersDb db = mkDb();
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        ],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-f-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('folder-action-rename')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('folder-action-delete')),
        findsOneWidget,
      );

      // Close the sheet so it cannot leak into the next test.
      await tester.tapAt(const Offset(540, 100));
      await tester.pumpAndSettle();
    });

    testWidgets('deleting a folder asks first and then unfiles, not deletes',
        (tester) async {
      final _FakeFoldersDb db = mkDb();
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        ],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-f-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-action-delete')));
      await tester.pumpAndSettle();

      // The confirmation must say the contents survive.
      expect(find.textContaining('No folder'), findsWidgets);
      expect(
        db.deletedFolderIds,
        isEmpty,
        reason: 'nothing is deleted before the user confirms',
      );

      await tester.tap(find.byKey(const ValueKey('folder-delete-confirm')));
      await tester.pumpAndSettle();

      expect(db.deletedFolderIds, <String>['f-1']);
      expect(
        find.byKey(const ValueKey('notebook-section-f-1')),
        findsNothing,
        reason: 'the header must leave the list',
      );
      expect(
        find.byKey(const ValueKey('notebook-row-nb-1')),
        findsOneWidget,
        reason: 'the notebook survives its folder',
      );
    });

    testWidgets('cancelling the delete keeps the folder', (tester) async {
      final _FakeFoldersDb db = mkDb();
      await mountList(
        tester,
        // Without at least one notebook the screen shows its empty state
        // instead of the section list.
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        ],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-f-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-action-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(db.deletedFolderIds, isEmpty);
      expect(
        find.byKey(const ValueKey('notebook-section-f-1')),
        findsOneWidget,
      );
    });

    testWidgets('renaming a folder updates its header', (tester) async {
      final _FakeFoldersDb db = mkDb();
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        ],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-f-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-action-rename')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Projects');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Work'), findsNothing);
    });

    testWidgets('the No-folder header has no actions', (tester) async {
      final _FakeFoldersDb db = mkDb();
      await mountList(
        tester,
        seed: <Notebook>[testNotebook(id: 'nb-2', title: 'Loose')],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-unfiled')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('folder-action-delete')),
        findsNothing,
        reason: 'the No-folder header is not a folder; it has no actions',
      );
    });
  });

  group('notebook multi-select', () {
    testWidgets('tap toggles rows and select-all covers every notebook',
        (tester) async {
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'One'),
          testNotebook(id: 'nb-2', title: 'Two'),
          testNotebook(id: 'nb-3', title: 'Three'),
        ],
      );

      await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Tapping a row now toggles it instead of opening the editor.
      await tester.tap(find.byKey(const ValueKey('notebook-row-nb-2')));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('notebook-selection-all')));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      // Select-all on a full selection clears it, as on dumps.
      await tester.tap(find.byKey(const ValueKey('notebook-selection-all')));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('the row menu button is hidden while selecting',
        (tester) async {
      await mountList(
        tester,
        seed: <Notebook>[testNotebook(id: 'nb-1', title: 'One')],
      );

      expect(
        find.byKey(const ValueKey('notebook-menu-nb-1')),
        findsOneWidget,
      );

      await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('notebook-menu-nb-1')),
        findsNothing,
        reason: 'a one-row menu is ambiguous while several rows are selected',
      );

      await unmount(tester);
    });

    testWidgets('cancel leaves selection mode with nothing deleted',
        (tester) async {
      await mountList(
        tester,
        seed: <Notebook>[testNotebook(id: 'nb-1', title: 'One')],
      );

      await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('notebook-selection-cancel')),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      expect(
        find.byKey(const ValueKey('notebook-menu-nb-1')),
        findsOneWidget,
      );
      expect(repository.deleted, isEmpty);

      await unmount(tester);
    });

    testWidgets('bulk delete confirms once and deletes every selected row',
        (tester) async {
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'One'),
          testNotebook(id: 'nb-2', title: 'Two'),
          testNotebook(id: 'nb-3', title: 'Three'),
        ],
      );

      await tester.longPress(find.byKey(const ValueKey('notebook-row-nb-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notebook-row-nb-2')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('notebook-selection-delete')),
      );
      await tester.pumpAndSettle();

      expect(
        repository.deleted,
        isEmpty,
        reason: 'nothing is deleted before the user confirms',
      );

      await tester.tap(
        find.byKey(const ValueKey('notebook-bulk-delete-confirm')),
      );
      await tester.pumpAndSettle();

      expect(repository.deleted, unorderedEquals(<String>['nb-1', 'nb-2']));
      expect(
        find.text('1 selected'),
        findsNothing,
        reason: 'selection mode ends after the bulk action',
      );

      await unmount(tester);
    });

    testWidgets('long-press on a folder header still opens folder actions',
        (tester) async {
      // Selection must not swallow the folder-header gesture shipped
      // earlier: headers are not rows.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _FakeFoldersDb db = _FakeFoldersDb()
        ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
      addTearDown(db.dispose);
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(id: 'nb-1', title: 'Filed', folderId: 'f-1'),
        ],
        db: db,
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(const ValueKey('notebook-section-f-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('folder-action-rename')),
        findsOneWidget,
      );
      expect(find.text('1 selected'), findsNothing);

      await unmount(tester);
    });
  });

  group('export to PDF', () {
    testWidgets('the menu offers Export to PDF and shares real PDF bytes',
        (tester) async {
      final List<({Uint8List bytes, String filename, String subject})> shared =
          <({Uint8List bytes, String filename, String subject})>[];
      await mountList(
        tester,
        seed: <Notebook>[
          testNotebook(
            id: 'nb-1',
            title: 'Field notes',
            blocks: const <NotebookBlock>[
              NotebookTextBlock(id: 'b-1', text: 'hello', x: 10, y: 10),
            ],
            strokes: <InkStroke>[
              InkStroke(
                id: 's-1',
                width: 3,
                points: const <InkPoint>[
                  InkPoint(x: 0, y: 0),
                  InkPoint(x: 40, y: 40),
                ],
              ),
            ],
          ),
        ],
        sharePdf: ({
          required Uint8List bytes,
          required String filename,
          required String subject,
        }) async {
          shared.add((bytes: bytes, filename: filename, subject: subject));
        },
      );

      await tester.tap(find.byKey(const ValueKey('notebook-menu-nb-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('item-action-exportPdf')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('item-action-exportPdf')));
      // The export rasterises off the test's fake-async clock.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();

      expect(shared, hasLength(1));
      expect(shared.single.filename, 'Field notes.pdf');
      expect(shared.single.subject, 'Field notes');
      expect(
        String.fromCharCodes(shared.single.bytes.sublist(0, 5)),
        '%PDF-',
        reason: 'the share must carry real PDF bytes, not a stub',
      );

      await unmount(tester);
    });

    testWidgets('a failed export reports instead of dying silently',
        (tester) async {
      await mountList(
        tester,
        seed: <Notebook>[testNotebook(id: 'nb-1', title: 'Field notes')],
        sharePdf: ({
          required Uint8List bytes,
          required String filename,
          required String subject,
        }) async {
          throw StateError('no share targets');
        },
      );

      await tester.tap(find.byKey(const ValueKey('notebook-menu-nb-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('item-action-exportPdf')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not export PDF'),
        findsOneWidget,
        reason: 'a tapped control that does nothing reads as a broken app',
      );

      await unmount(tester);
    });
  });
}
