// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';

import '../support/dump_view_fixture.dart';

/// Leftovers sweep L5: `DumpsListScreen(filterIds: ...)` presents only the
/// rows whose id is in the set; null keeps the ordinary unrestricted list.
/// The Home speaker back-fill banner opens the list this way.

Future<void> _mount(WidgetTester tester, Set<String>? filterIds) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        deletionEligibilityProvider.overrideWith(
          (_) => Stream.value(const <String, Eligibility>{}),
        ),
        dumpsProvider.overrideWith(
          (_) => Stream.value(
            <DumpRow>[viewRow('keep-a'), viewRow('drop-b'), viewRow('keep-c')],
          ),
        ),
      ],
      child: MaterialApp(home: DumpsListScreen(filterIds: filterIds)),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('filterIds keeps only the named rows', (tester) async {
    await _mount(tester, <String>{'keep-a', 'keep-c', 'never-existed'});

    expect(find.text('keep-a'), findsOneWidget);
    expect(find.text('keep-c'), findsOneWidget);
    expect(find.text('drop-b'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('null filterIds is the ordinary unrestricted list',
      (tester) async {
    await _mount(tester, null);

    expect(find.text('keep-a'), findsOneWidget);
    expect(find.text('drop-b'), findsOneWidget);
    expect(find.text('keep-c'), findsOneWidget);
  });

  testWidgets('filterIds matching nothing shows its own empty state',
      (tester) async {
    await _mount(tester, <String>{'gone'});

    expect(find.text('Those recordings are no longer here'), findsOneWidget);
    expect(find.text('No recordings yet — record one!'), findsNothing);
  });
}
