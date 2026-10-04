// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared tags on the recordings list: the row ⋮ sheet offers Edit tags and
// opens the shared sheet for that recording, long-press stays multi-select,
// tags ride the title line, and the SAME tag filter control as the notebook
// list narrows the rows (and prunes any selection it hides).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/tag_repository.dart';
import 'package:tangent/widgets/edit_tags_sheet.dart';
import 'package:tangent/widgets/item_action_sheet.dart';
import 'package:tangent/widgets/tag_widgets.dart';

import '../support/dump_selection_fixture.dart';
import '../support/fake_tag_store.dart';

void main() {
  late FakeTagStore store;
  late CountingDeletion deletion;

  setUp(() {
    store = FakeTagStore();
    deletion = CountingDeletion();
  });
  tearDown(() => store.dispose());

  Future<void> mount(WidgetTester tester) async {
    await mountSelection(
      tester,
      deletion,
      extraOverrides: [tagStoreProvider.overrideWithValue(store)],
    );
    // Tag projections are streams: one more frame to deliver.
    await pumpSelection(tester);
  }

  testWidgets('row ⋮ → Edit tags opens the shared sheet for that recording', (
    tester,
  ) async {
    final String work = store.seedTag('Work');
    await mount(tester);

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-b')));
    await pumpSelection(tester);
    final Finder editTags = find.byKey(
      ItemActionSheet.keyFor(ItemAction.editTags),
    );
    expect(editTags, findsOneWidget);
    await tester.tap(editTags);
    await tester.pumpAndSettle();

    final EditTagsSheet sheet = tester.widget<EditTagsSheet>(
      find.byType(EditTagsSheet),
    );
    expect((sheet.targetType, sheet.targetId), (TagTarget.dump, 'fixture-b'));
    await tester.tap(find.byKey(EditTagsSheet.toggleKey(work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditTagsSheet.doneKey));
    await tester.pumpAndSettle();

    expect(store.tagIdsOn(TagTarget.dump, 'fixture-b'), <String>{work});
    expect(find.byKey(const ValueKey('dump-tags-fixture-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('dump-tags-fixture-a')), findsNothing);
  });

  testWidgets('long-press still selects and never opens a sheet', (
    tester,
  ) async {
    store.seedTag('Work');
    await mount(tester);
    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-select-fixture-a')), findsOneWidget);
    expect(find.byType(ItemActionSheet), findsNothing);
    expect(find.byType(EditTagsSheet), findsNothing);
  });

  testWidgets('tags do not grow the row', (tester) async {
    for (int i = 0; i < 10; i++) {
      store.seedLink(
        TagTarget.dump,
        'fixture-a',
        store.seedTag('a fairly long tag name $i'),
      );
    }
    await mount(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('dump-row-fixture-a'))).height,
      tester.getSize(find.byKey(const ValueKey('dump-row-fixture-b'))).height,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the shared tag filter narrows rows and prunes hidden selection',
    (tester) async {
      final String work = store.seedTag('Work');
      store.seedLink(TagTarget.dump, 'fixture-a', work);
      // A NOTEBOOK carrying the tag under the same id must not leak in.
      store.seedLink(TagTarget.notebook, 'fixture-b', work);
      await mount(tester);

      await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-b')));
      await pumpSelection(tester);
      expect(
        find.byKey(const ValueKey('dump-select-fixture-b')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(TagFilterBar.menuKey));
      await pumpSelection(tester);
      await tester.tap(find.byKey(TagFilterBar.keyFor(work)));
      await pumpSelection(tester);

      expect(find.byKey(const ValueKey('dump-row-fixture-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dump-row-fixture-b')), findsNothing);
      expect(
        find.byKey(const ValueKey('selection-cancel')),
        findsNothing,
        reason: 'changing a filter cancels selection, like Mode/Transcript',
      );
      expect(find.text('Tag · #Work'), findsOneWidget);

      // Select-all while filtered covers ONLY the visible row, and the bulk
      // delete it feeds asks about that row alone.
      // (The long-pressed row already fills the visible selection, so the
      // first tap toggles it off; the second selects every visible row.)
      await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
      await pumpSelection(tester);
      await tester.tap(find.byKey(const ValueKey('selection-all')));
      await pumpSelection(tester);
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('selection-all')));
      await pumpSelection(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('selection-delete')));
      await pumpSelection(tester);
      expect(deletion.previews, <Set<String>>[
        <String>{'fixture-a'},
      ]);
      await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
      await pumpSelection(tester);
      expect(deletion.deletes, isEmpty);

      await tester.tap(find.byKey(TagFilterBar.menuKey));
      await pumpSelection(tester);
      await tester.tap(find.byKey(TagFilterBar.allKey));
      await pumpSelection(tester);
      expect(find.byKey(const ValueKey('dump-row-fixture-b')), findsOneWidget);
    },
  );

  testWidgets('deleting the filtered tag elsewhere falls back to All', (
    tester,
  ) async {
    final String work = store.seedTag('Work');
    store.seedTag('Home');
    store.seedLink(TagTarget.dump, 'fixture-a', work);
    await mount(tester);
    await tester.tap(find.byKey(TagFilterBar.menuKey));
    await pumpSelection(tester);
    await tester.tap(find.byKey(TagFilterBar.keyFor(work)));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-row-fixture-b')), findsNothing);

    await store.deleteTag(work);
    await pumpSelection(tester);

    expect(find.byKey(const ValueKey('dump-row-fixture-b')), findsOneWidget);
    expect(find.text('Tag · All'), findsOneWidget);
  });
}
