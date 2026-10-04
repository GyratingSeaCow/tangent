// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared Edit tags sheet: attach existing, create inline, remove,
// rename, and delete-everywhere behind ONE confirmation that says so.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/tag_repository.dart';
import 'package:tangent/widgets/edit_tags_sheet.dart';

import '../support/fake_tag_store.dart';

void main() {
  late FakeTagStore store;

  setUp(() => store = FakeTagStore());
  tearDown(() => store.dispose());

  Future<void> openSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[tagStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showEditTagsSheet(
                  context,
                  targetType: TagTarget.notebook,
                  targetId: 'nb-1',
                  itemTitle: 'Ideas',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(EditTagsSheet), findsOneWidget);
  }

  bool checked(WidgetTester tester, String tagId) => tester
      .widget<Checkbox>(find.byKey(EditTagsSheet.toggleKey(tagId)))
      .value!;

  testWidgets('attach an existing tag, then remove it', (tester) async {
    final String work = store.seedTag('Work');
    store.seedTag('Home');
    await openSheet(tester);

    expect(checked(tester, work), isFalse);
    await tester.tap(find.byKey(EditTagsSheet.toggleKey(work)));
    await tester.pumpAndSettle();
    expect(store.tagIdsOn(TagTarget.notebook, 'nb-1'), <String>{work});
    expect(checked(tester, work), isTrue, reason: 'renders from the store');

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(store.tagIdsOn(TagTarget.notebook, 'nb-1'), isEmpty);
    expect(checked(tester, work), isFalse);
  });

  testWidgets('create inline from the soft keyboard Done action', (
    tester,
  ) async {
    await openSheet(tester);
    expect(
      find.text('No tags yet — type a name to create one.'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(EditTagsSheet.fieldKey), 'Errands');
    await tester.pump();
    expect(find.byKey(EditTagsSheet.createKey), findsOneWidget);
    final TextField field = tester.widget<TextField>(
      find.byKey(EditTagsSheet.fieldKey),
    );
    expect(field.textInputAction, TextInputAction.done);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(store.tags.map((TagSummary t) => t.name), <String>['Errands']);
    expect(store.tagIdsOn(TagTarget.notebook, 'nb-1'), <String>{
      store.tags.single.id,
    }, reason: 'a created tag is attached in the same step');
    expect(
      tester
          .widget<TextField>(find.byKey(EditTagsSheet.fieldKey))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('the Create row creates; a taken name attaches, never twins', (
    tester,
  ) async {
    final String work = store.seedTag('Work');
    await openSheet(tester);

    await tester.enterText(find.byKey(EditTagsSheet.fieldKey), 'work');
    await tester.pump();
    expect(
      find.byKey(EditTagsSheet.createKey),
      findsNothing,
      reason: 'no Create offer for a name that already exists',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.tags, hasLength(1));
    expect(store.tagIdsOn(TagTarget.notebook, 'nb-1'), <String>{work});

    await tester.enterText(find.byKey(EditTagsSheet.fieldKey), 'Reading list');
    await tester.pump();
    await tester.tap(find.byKey(EditTagsSheet.createKey));
    await tester.pumpAndSettle();
    expect(store.tags.map((TagSummary t) => t.name), contains('Reading list'));
    expect(store.tagIdsOn(TagTarget.notebook, 'nb-1'), hasLength(2));
  });

  testWidgets('rename through the tag menu; a taken name shows an error', (
    tester,
  ) async {
    final String work = store.seedTag('Work');
    store.seedTag('Home');
    await openSheet(tester);

    await tester.tap(find.byKey(EditTagsSheet.menuKey(work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditTagsSheet.renameKey(work)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('tag-rename-field')),
      'Job',
    );
    await tester.tap(find.byKey(const ValueKey<String>('tag-rename-save')));
    await tester.pumpAndSettle();
    expect(store.tags.firstWhere((t) => t.id == work).name, 'Job');
    expect(find.text('Job'), findsOneWidget);

    await tester.tap(find.byKey(EditTagsSheet.menuKey(work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditTagsSheet.renameKey(work)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('tag-rename-field')),
      'home',
    );
    await tester.tap(find.byKey(const ValueKey<String>('tag-rename-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(EditTagsSheet.errorKey), findsOneWidget);
    expect(store.tags.firstWhere((t) => t.id == work).name, 'Job');
  });

  testWidgets(
    'delete asks ONCE, says it removes the tag from every notebook and '
    'recording on all devices, and does exactly that',
    (tester) async {
      final String work = store.seedTag('Work');
      store
        ..seedLink(TagTarget.notebook, 'nb-1', work)
        ..seedLink(TagTarget.notebook, 'nb-2', work)
        ..seedLink(TagTarget.dump, 'dump-1', work);
      await openSheet(tester);

      Future<void> openDelete() async {
        await tester.tap(find.byKey(EditTagsSheet.menuKey(work)));
        await tester.pumpAndSettle();
        expect(find.text('Delete tag everywhere'), findsOneWidget);
        await tester.tap(find.byKey(EditTagsSheet.deleteKey(work)));
        await tester.pumpAndSettle();
      }

      await openDelete();
      final String message = tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('tag-delete-message')),
          )
          .data!;
      expect(message, contains('every notebook and recording'));
      expect(message, contains('(3 items)'));
      expect(message, contains('all your synced devices'));
      expect(message, contains('themselves are not deleted'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.deletedTagIds, isEmpty, reason: 'Cancel deletes nothing');

      await openDelete();
      await tester.tap(
        find.byKey(const ValueKey<String>('tag-delete-confirm')),
      );
      await tester.pumpAndSettle();

      expect(store.deletedTagIds, <String>[work]);
      expect(store.tagIdsOn(TagTarget.notebook, 'nb-2'), isEmpty);
      expect(store.tagIdsOn(TagTarget.dump, 'dump-1'), isEmpty);
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'one confirmation',
      );
      expect(find.byKey(EditTagsSheet.toggleKey(work)), findsNothing);
    },
  );
}
