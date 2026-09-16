// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/dump_selection_fixture.dart';

void main() {
  testWidgets(
      'long press selects; row and circular control never navigate; Cancel is safe',
      (tester) async {
    var opens = 0;
    final service = CountingDeletion();
    await mountSelection(tester, service, onOpen: (_, __) => opens++);
    await tester.longPress(find.text('fixture-a'));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-select-fixture-a')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dump-row-fixture-b')));
    await pumpSelection(tester);
    expect(opens, 0);
    await tester.tap(find.byKey(const ValueKey('selection-all')));
    await pumpSelection(tester);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
            .onPressed,
        isNull,);
    await tester.tap(find.byKey(const ValueKey('selection-cancel')));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-select-fixture-a')), findsNothing);
    expect(service.deletes, isEmpty);
    expect(service.retries, isEmpty);
    await tester.tap(find.byKey(const ValueKey('dump-row-fixture-a')));
    expect(opens, 1);
  });
}
