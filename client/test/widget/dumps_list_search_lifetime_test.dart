// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';

import '../support/dump_view_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backing out clears search before the dumps list is reopened',
      (WidgetTester tester) async {
    final List<DumpRow> rows = <DumpRow>[
      viewRow('alpha-recording'),
      viewRow('bravo-recording'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          deletionEligibilityProvider.overrideWith(
            (_) => Stream.value(const <String, Eligibility>{}),
          ),
          dumpsProvider.overrideWith((_) => Stream.value(rows)),
          searchResultsProvider.overrideWith((ref) {
            final String query = ref.watch(searchQueryProvider);
            return Stream.value(
              rows.where((DumpRow row) => row.title.contains(query)).toList(),
            );
          }),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-dumps'),
                onPressed: () => unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const DumpsListScreen(),
                    ),
                  ),
                ),
                child: const Text('Open recordings'),
              ),
            ),
          ),
        ),
      ),
    );

    Future<void> openList() async {
      await tester.tap(find.byKey(const ValueKey('open-dumps')));
      await tester.pumpAndSettle();
    }

    await openList();
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('alpha-recording'), findsOneWidget);
    expect(find.text('bravo-recording'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openList();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('alpha-recording'), findsOneWidget);
    expect(find.text('bravo-recording'), findsOneWidget);
  });
}
