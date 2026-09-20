// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/dump_selection_fixture.dart';

/// Desktop parity: a mouse right-click does what long-press does on the
/// dumps list — enters multi-select. Same fixture as dumps_selection_test,
/// same assertions, different input device.
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

  testWidgets('right-click selects, exactly like long-press', (tester) async {
    var opens = 0;
    final service = CountingDeletion();
    await mountSelection(tester, service, onOpen: (_, __) => opens++);

    await rightClick(tester, find.byKey(const ValueKey('dump-row-fixture-a')));

    expect(
      find.byKey(const ValueKey('dump-select-fixture-a')),
      findsOneWidget,
      reason: 'right-click must enter selection mode, as long-press does',
    );
    expect(opens, 0, reason: 'right-click must never navigate');
    expect(service.deletes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
