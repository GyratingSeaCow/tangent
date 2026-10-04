// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared tags on the notebook list: Edit tags is reachable from BOTH the
// list row's ⋮ and the cover grid's ⋮ (the two menus share one handler, and
// this proves the seam from each), long-press still selects, tags render on
// one line without growing the row, the tag filter narrows the library, and
// a bulk action never reaches a row the filter hides.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/tag_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/screens/settings/handwriting_search_section.dart'
    show handwritingSearchEnabledProvider;
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/edit_tags_sheet.dart';
import 'package:tangent/widgets/item_action_sheet.dart';
import 'package:tangent/widgets/tag_widgets.dart';

import '../support/fake_notebook_repository.dart';
import '../support/fake_tag_store.dart';

/// Bulk delete goes through persistence; forward it to the fake repository
/// so `repository.deleted` records exactly what the screen deleted.
class _ForwardingNotebookPersistence implements NotebookPersistence {
  _ForwardingNotebookPersistence(this._repository);

  final NotebookRepository _repository;

  @override
  Future<ComponentResult> deleteNotebook(String id) async {
    await _repository.deleteNotebook(id);
    return (state: ComponentState.removed, problem: null);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeNotebookRepository repository;
  late FakeTagStore store;

  Future<void> mount(
    WidgetTester tester, {
    required List<Notebook> seed,
    bool covers = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'notebooks.coverView': covers,
    });
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
            (_) => Stream<List<Folder>>.value(const <Folder>[]),
          ),
          handwritingSearchEnabledProvider.overrideWith((ref) => false),
          tagStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(home: NotebookListScreen()),
      ),
    );
    // Stream providers deliver a frame after mount; the cover preference
    // loads asynchronously too.
    await tester.pumpAndSettle();
  }

  setUp(() => store = FakeTagStore());
  tearDown(() => store.dispose());

  final List<Notebook> library = <Notebook>[
    testNotebook(id: 'nb-1', title: 'Ideas'),
    testNotebook(id: 'nb-2', title: 'Groceries'),
  ];

  Future<void> openEditTagsFrom(WidgetTester tester, Key menu) async {
    await tester.tap(find.byKey(menu));
    await tester.pumpAndSettle();
    final Finder editTags = find.byKey(
      ItemActionSheet.keyFor(ItemAction.editTags),
    );
    expect(editTags, findsOneWidget, reason: 'Edit tags is on this ⋮ sheet');
    expect(find.text('Edit tags'), findsOneWidget);
    await tester.tap(editTags);
    await tester.pumpAndSettle();
  }

  testWidgets('list ⋮ → Edit tags opens the shared sheet for THAT notebook, '
      'and the attached tag shows on its row', (tester) async {
    final String work = store.seedTag('Work');
    await mount(tester, seed: library);

    await openEditTagsFrom(
      tester,
      const ValueKey<String>('notebook-menu-nb-2'),
    );
    final EditTagsSheet sheet = tester.widget<EditTagsSheet>(
      find.byType(EditTagsSheet),
    );
    expect(
      (sheet.targetType, sheet.targetId, sheet.itemTitle),
      (TagTarget.notebook, 'nb-2', 'Groceries'),
    );
    await tester.tap(find.byKey(EditTagsSheet.toggleKey(work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditTagsSheet.doneKey));
    await tester.pumpAndSettle();

    expect(store.tagIdsOn(TagTarget.notebook, 'nb-2'), <String>{work});
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('notebook-tags-nb-2')),
              matching: find.byType(Text),
            ),
          )
          .data,
      '#Work',
    );
    expect(
      find.byKey(const ValueKey<String>('notebook-tags-nb-1')),
      findsNothing,
    );
  });

  testWidgets('cover grid ⋮ → Edit tags opens the same sheet; tags ride the '
      'cover face', (tester) async {
    final String work = store.seedTag('Work');
    await mount(tester, seed: library, covers: true);
    expect(
      find.byKey(const ValueKey<String>('notebook-cover-nb-1')),
      findsOneWidget,
    );

    await openEditTagsFrom(
      tester,
      const ValueKey<String>('notebook-cover-menu-nb-1'),
    );
    expect(
      tester.widget<EditTagsSheet>(find.byType(EditTagsSheet)).targetId,
      'nb-1',
    );
    await tester.tap(find.byKey(EditTagsSheet.toggleKey(work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditTagsSheet.doneKey));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('notebook-cover-tags-nb-1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull, reason: 'no cover overflow');
  });

  testWidgets('long-press still enters selection, in list AND cover view', (
    tester,
  ) async {
    store.seedTag('Work');
    await mount(tester, seed: library);
    await tester.longPress(
      find.byKey(const ValueKey<String>('notebook-row-nb-1')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('notebook-select-nb-1')),
      findsOneWidget,
    );
    expect(find.byType(ItemActionSheet), findsNothing);
    expect(find.byType(EditTagsSheet), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, seed: library, covers: true);
    await tester.longPress(
      find.byKey(const ValueKey<String>('notebook-cover-nb-1')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('notebook-selection-cancel')),
      findsOneWidget,
    );
    expect(find.byType(ItemActionSheet), findsNothing);
  });

  testWidgets('many long tags stay on one line and do not grow the row', (
    tester,
  ) async {
    final List<String> ids = <String>[
      for (int i = 0; i < 12; i++) store.seedTag('really long tag number $i'),
    ];
    for (final String id in ids) {
      store.seedLink(TagTarget.notebook, 'nb-1', id);
    }
    await mount(tester, seed: library);

    final Text label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('notebook-tags-nb-1')),
        matching: find.byType(Text),
      ),
    );
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('notebook-row-nb-1')))
          .height,
      tester
          .getSize(find.byKey(const ValueKey<String>('notebook-row-nb-2')))
          .height,
      reason: 'a tagged row is exactly as tall as an untagged one',
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('notebook-tags-nb-1')))
          .width,
      lessThan(1080 * 0.5),
      reason: 'the title keeps the larger share of the line',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tag filter narrows the library and All restores it', (
    tester,
  ) async {
    final String work = store.seedTag('Work');
    store.seedTag('Unused');
    store.seedLink(TagTarget.notebook, 'nb-1', work);
    // A dump carrying the tag must not leak into the notebook filter.
    store.seedLink(TagTarget.dump, 'nb-2', work);
    await mount(tester, seed: library);

    await tester.tap(find.byKey(TagFilterBar.menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(TagFilterBar.keyFor(work)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-2')),
      findsNothing,
    );
    expect(find.text('Tag · #Work'), findsOneWidget);

    await tester.tap(find.byKey(TagFilterBar.menuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(TagFilterBar.allKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-2')),
      findsOneWidget,
    );
  });

  testWidgets('a tag filter change cancels selection, and bulk delete never '
      'touches a row the filter hides', (tester) async {
    final String work = store.seedTag('Work');
    store.seedLink(TagTarget.notebook, 'nb-1', work);
    store.seedLink(TagTarget.notebook, 'nb-2', work);
    await mount(
      tester,
      seed: <Notebook>[
        ...library,
        testNotebook(id: 'nb-3', title: 'Untagged'),
      ],
    );
    Future<void> filterBy(Key key) async {
      await tester.tap(find.byKey(TagFilterBar.menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    // Select the row the filter is about to hide, then filter.
    await tester.longPress(
      find.byKey(const ValueKey<String>('notebook-row-nb-3')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await filterBy(TagFilterBar.keyFor(work));
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-3')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('notebook-selection-cancel')),
      findsNothing,
      reason: 'a filter change cancels selection, as on the recordings list',
    );

    // Select every visible row; then one loses the tag (a sync pull, say)
    // and drops out of the filtered list mid-selection.
    await tester.longPress(
      find.byKey(const ValueKey<String>('notebook-row-nb-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('notebook-selection-all')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await store.unassignTag(
      tagId: work,
      targetType: TagTarget.notebook,
      targetId: 'nb-2',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-2')),
      findsNothing,
    );
    expect(
      find.text('1 selected'),
      findsOneWidget,
      reason: 'the count never answers for a row the filter hides',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('notebook-selection-delete')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 notebook?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('notebook-bulk-delete-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.deleted, <String>['nb-1']);

    // Back to All: the hidden rows were never touched.
    await filterBy(TagFilterBar.allKey);
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('notebook-row-nb-3')),
      findsOneWidget,
    );
  });

  testWidgets('no tags, no filter control', (tester) async {
    await mount(tester, seed: library);
    expect(find.byKey(TagFilterBar.menuKey), findsNothing);
  });
}
