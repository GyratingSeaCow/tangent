// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/item_action_sheet.dart';
import '../support/dump_selection_fixture.dart';

/// Desktop parity: right-click and touch long-press invoke the same row action
/// handler. Selection begins only through the shared sheet's Select action.
void main() {
  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(finder),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await pumpSelection(tester);
  }

  testWidgets(
    'right-click opens the shared sheet and Select enters selection',
    (tester) async {
      var opens = 0;
      final service = CountingDeletion();
      await mountSelection(tester, service, onOpen: (_, _) => opens++);

      await rightClick(
        tester,
        find.byKey(const ValueKey('dump-row-fixture-a')),
      );

      expect(find.byType(ItemActionSheet), findsOneWidget);
      expect(
        find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
        findsOneWidget,
        reason: 'right-click must invoke the same action-sheet handler',
      );
      expect(
        find.byKey(const ValueKey('dump-select-fixture-a')),
        findsNothing,
        reason: 'selection starts only after choosing Select',
      );
      final Finder select = find.byKey(
        ItemActionSheet.keyFor(ItemAction.select),
      );
      await tester.scrollUntilVisible(
        select,
        60,
        scrollable: find.descendant(
          of: find.byType(ItemActionSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await pumpSelection(tester);
      await tester.tap(select);
      await pumpSelection(tester);

      expect(
        find.byKey(const ValueKey('dump-select-fixture-a')),
        findsOneWidget,
      );
      expect(opens, 0, reason: 'right-click must never navigate');
      expect(service.deletes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
