// SPDX-License-Identifier: AGPL-3.0-or-later
/// Search-result cards (search-depth spec §2): a row whose transcript
/// matched shows one snippet line with the hits bold, and an 'N matches'
/// chip only when there is more than one hit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/services/transcript_search.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

Future<ProviderContainer> _mountSearch(WidgetTester tester) async {
  final container = await mountSelection(
    tester,
    CountingDeletion(),
    extraOverrides: <Override>[
      searchQueryProvider.overrideWith((_) => 'budget'),
      searchMatchesProvider.overrideWith(
        (_) => Stream.value(const <String, DumpSearchMatch>{
          'fixture-a': DumpSearchMatch(
            snippet: 'the <b>budget</b> is tight',
            matchCount: 3,
            titleMatched: false,
          ),
          'fixture-b': DumpSearchMatch(
            snippet: 'one <b>budget</b> only',
            matchCount: 1,
            titleMatched: false,
          ),
        }),
      ),
    ],
  );
  // The StreamProvider's first value lands a frame after mount.
  await pumpSelection(tester);
  await pumpSelection(tester);
  return container;
}

void main() {
  testWidgets('a matched row shows its snippet with bold hits',
      (WidgetTester tester) async {
    await _mountSearch(tester);

    final snippet = find.byKey(const ValueKey('search-snippet-fixture-a'));
    expect(snippet, findsOneWidget);
    final span = tester.widget<Text>(snippet).textSpan! as TextSpan;
    final bold = span.children!
        .cast<TextSpan>()
        .where((s) => s.style?.fontWeight == FontWeight.bold)
        .map((s) => s.text)
        .toList();
    expect(bold, ['budget']);
    expect(span.toPlainText(), 'the budget is tight');
  });

  testWidgets('the count chip appears only past one match',
      (WidgetTester tester) async {
    await _mountSearch(tester);

    expect(
      find.byKey(const ValueKey('search-match-count-fixture-a')),
      findsOneWidget,
    );
    expect(find.text('3 matches'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-match-count-fixture-b')),
      findsNothing,
      reason: 'a single hit must not shout a count',
    );
  });

  testWidgets('no search: no snippet line at all', (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());
    expect(
      find.byKey(const ValueKey('search-snippet-fixture-a')),
      findsNothing,
    );
  });

  test('a title hit bolds the matched phrase in the title', () {
    final DumpRow row = viewRow('fixture-a').copyWith(title: 'Budget review');
    const match = DumpSearchMatch(
      snippet: 'ignored',
      matchCount: 1,
      titleMatched: true,
    );
    expect(searchSnippetRuns(row, match, 'budget'), <SnippetRun>[
      (text: 'Budget', bold: true),
      (text: ' review', bold: false),
    ]);
  });
}
