// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared item menu on the recordings list.
//
// Design note: long-press here does NOT open the sheet. The recordings list
// already uses long-press for multi-select, which is the entry point to the
// audited bulk local-deletion flow, and 28 existing tests encode that contract
// deliberately ("long press selects; row and circular control never
// navigate"). Overloading the gesture broke every one of them.
//
// So per-item actions live on a per-row menu button instead, the same split
// Drive, Files and Samsung's own apps use. Notebooks keep long-press because
// nothing else claimed the gesture there.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/widgets/item_action_sheet.dart';
import '../support/dump_selection_fixture.dart';

void main() {
  testWidgets('the menu button opens the shared sheet',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'recordings get the same menu as every other list',
    );
  });

  testWidgets('long-press still enters multi-select, not the sheet',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsNothing,
      reason: 'long-press is the bulk-delete entry point and must not change',
    );
    expect(
      find.byKey(const ValueKey('dump-select-fixture-a')),
      findsOneWidget,
      reason: 'long-press must still enter selection mode',
    );
  });

  testWidgets('the menu button is hidden while a selection is active',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(const ValueKey('dump-more-fixture-a')),
      findsNothing,
      reason: 'a one-row menu during a multi-row selection is ambiguous',
    );
  });

  testWidgets('the sheet offers Select, which enters multi-select',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.select)));
    await pumpSelection(tester);

    expect(
      find.byKey(const ValueKey('dump-select-fixture-a')),
      findsOneWidget,
      reason: 'Select must reach the existing bulk-delete flow',
    );
    expect(find.byKey(const ValueKey('selection-all')), findsOneWidget);
  });

  testWidgets('a recording that cannot be deleted shows a disabled Delete',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    // Make fixture-b ineligible the way the app does: through the eligibility
    // map the storage layer publishes. Both fixtures ship eligible, so this
    // must be set explicitly rather than assumed.
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('dump-row-fixture-a'))),
    );
    container.read(eligibilityFixture.notifier).state = <String, Eligibility>{
      'fixture-a': Eligibility.eligible,
      'fixture-b': Eligibility.syncing,
    };
    await pumpSelection(tester);

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-b')));
    await pumpSelection(tester);

    final Finder deleteRow =
        find.byKey(ItemActionSheet.keyFor(ItemAction.delete));
    // Delete sits at the bottom of a scrollable sheet and is built lazily, so
    // it must be scrolled into view before it can be inspected. The scrollable
    // must be named explicitly: the recordings list behind the sheet is also
    // scrollable, and an ambiguous finder throws.
    await tester.scrollUntilVisible(
      deleteRow,
      60,
      scrollable: find.descendant(
        of: find.byType(ItemActionSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await pumpSelection(tester);

    expect(deleteRow, findsOneWidget, reason: 'Delete is shown, not hidden');
    expect(
      tester.widget<ListTile>(deleteRow).enabled,
      isFalse,
      reason: 'the eligibility rules must survive the new entry point',
    );
    expect(
      find.text('Sync in progress'),
      findsOneWidget,
      reason: 'the existing eligibility wording explains why',
    );
  });
}
