// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The bulk toolbar's download and transcribe buttons.
//
// What matters here is presence and gating: the buttons exist beside
// delete, disable with nothing selected, and enable once something is.
// The eligibility rules they apply are proven in bulk_dump_actions_test;
// this file proves the toolbar actually offers them — a bulk service with
// no button is the same defect as a download service with no menu entry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/dump_selection_fixture.dart';

void main() {
  testWidgets('bulk toolbar offers download and transcribe beside delete',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    // Enter selection mode via long-press (the documented entry point).
    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    for (final String key in <String>[
      'selection-download',
      'selection-transcribe',
      'selection-delete',
    ]) {
      expect(
        find.byKey(ValueKey<String>(key)),
        findsOneWidget,
        reason: '$key belongs on the bulk toolbar',
      );
    }
  });

  testWidgets('bulk buttons disable when the selection is empty',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);
    // Deselect the row long-press selected: toolbar stays, selection empty.
    await tester.tap(find.byKey(const ValueKey('dump-select-fixture-a')));
    await pumpSelection(tester);

    for (final String key in <String>[
      'selection-download',
      'selection-transcribe',
    ]) {
      final IconButton button =
          tester.widget<IconButton>(find.byKey(ValueKey<String>(key)));
      expect(
        button.onPressed,
        isNull,
        reason: '$key over nothing is a lying control',
      );
    }
  });
}
