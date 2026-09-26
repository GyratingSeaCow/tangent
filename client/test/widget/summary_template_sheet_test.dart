// SPDX-License-Identifier: AGPL-3.0-or-later
/// The summary template picker renders FROM the server's catalogue (no
/// hardcoded list), hides 'Custom' until the custom slot is configured,
/// marks the dump's current effective template, and pops the tapped id.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/dump/summarize_flow.dart';
import 'package:tangent/services/summaries_client.dart';

const List<SummaryTemplate> _serverList = <SummaryTemplate>[
  SummaryTemplate(id: 'meeting', displayName: 'Meeting'),
  SummaryTemplate(id: 'brain_dump', displayName: 'Brain dump'),
  SummaryTemplate(id: 'lecture', displayName: 'Lecture'),
  SummaryTemplate(id: 'actions_only', displayName: 'Actions only'),
  SummaryTemplate(id: 'custom', displayName: 'Custom'),
];

class _Harness {
  String? result;
  bool completed = false;
}

Future<_Harness> _open(
  WidgetTester tester, {
  bool customConfigured = false,
  String currentId = 'meeting',
  List<SummaryTemplate> templates = _serverList,
}) async {
  final _Harness harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              harness.result = await SummaryTemplateSheet.show(
                context,
                catalogue: SummaryTemplates(
                  templates: templates,
                  customConfigured: customConfigured,
                ),
                currentId: currentId,
              );
              harness.completed = true;
            },
            child: const Text('open picker'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open picker'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('the sheet names itself and lists the server presets in order',
      (tester) async {
    await _open(tester);

    expect(
      find.byKey(const ValueKey<String>('summary-template-sheet')),
      findsOneWidget,
    );
    expect(find.text('Summary template'), findsOneWidget);
    final List<String> ids = <String>[
      'meeting',
      'brain_dump',
      'lecture',
      'actions_only',
    ];
    double lastY = -1;
    for (final String id in ids) {
      final Finder row = find.byKey(ValueKey<String>('summary-template-$id'));
      expect(row, findsOneWidget, reason: '$id comes from the server list');
      final double y = tester.getTopLeft(row).dy;
      expect(y, greaterThan(lastY), reason: 'server order is preserved');
      lastY = y;
    }
    expect(
      find.text('Brain dump'),
      findsOneWidget,
      reason: 'display names come from the server, not the id',
    );
  });

  testWidgets('Custom is hidden while the custom slot is not configured',
      (tester) async {
    await _open(tester, customConfigured: false);

    expect(
      find.byKey(const ValueKey<String>('summary-template-custom')),
      findsNothing,
      reason: 'an empty custom slot is not something to offer',
    );
    expect(find.text('Custom'), findsNothing);
  });

  testWidgets('Custom appears once the server says it is configured',
      (tester) async {
    await _open(tester, customConfigured: true);

    expect(
      find.byKey(const ValueKey<String>('summary-template-custom')),
      findsOneWidget,
    );
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('the current effective template is marked, others are not',
      (tester) async {
    await _open(tester, currentId: 'lecture');

    expect(
      find.byKey(const ValueKey<String>('summary-template-current-lecture')),
      findsOneWidget,
    );
    expect(
      find.byIcon(Icons.check),
      findsOneWidget,
      reason: 'exactly one row is current',
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey<String>('summary-template-lecture')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey<String>('summary-template-meeting')),
          )
          .selected,
      isFalse,
    );
  });

  testWidgets('tapping a row pops its id', (tester) async {
    final _Harness harness = await _open(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('summary-template-actions_only')),
    );
    await tester.pumpAndSettle();

    expect(harness.completed, isTrue);
    expect(harness.result, 'actions_only');
    expect(
      find.byKey(const ValueKey<String>('summary-template-sheet')),
      findsNothing,
    );
  });

  testWidgets('tapping the CURRENT row still pops it (re-run same template)',
      (tester) async {
    final _Harness harness = await _open(tester, currentId: 'meeting');

    await tester.tap(
      find.byKey(const ValueKey<String>('summary-template-meeting')),
    );
    await tester.pumpAndSettle();

    expect(
      harness.result,
      'meeting',
      reason: 'Summarize again with the same template is a valid ask',
    );
  });

  testWidgets('dismissing the sheet pops null', (tester) async {
    final _Harness harness = await _open(tester);

    // Tap the barrier above the sheet.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(harness.completed, isTrue);
    expect(harness.result, isNull);
  });

  testWidgets('an empty catalogue says so instead of rendering nothing',
      (tester) async {
    await _open(tester, templates: const <SummaryTemplate>[]);

    expect(find.text('No templates available'), findsOneWidget);
  });
}
