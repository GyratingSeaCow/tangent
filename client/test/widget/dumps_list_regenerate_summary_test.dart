// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Task 4: the '⋮ > Regenerate summary' action on the recordings list.
//
// The action follows the download-action pattern: HIDDEN when it can never
// apply to this row (no transcript — nothing to summarize) and hidden while
// the AI-summaries capability is off (the OCR precedent: while the feature
// is off, none of its UI appears anywhere). The capability gate is
// summariesEnabledProvider — the device's local mirror that only rests ON
// after the Settings wizard installed and enabled the capability. If that
// mirror is stale (uninstalled from another device), the server's typed 409
// routes the user to Settings rather than failing cryptically.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart';
import 'package:tangent/services/summaries_client.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

/// A recording that has been transcribed — the only kind the regenerate
/// endpoint accepts.
DumpRow transcribedRow(String id) => viewRow(id).copyWith(
      transcript: const Value<String?>('[00:00] Alice: hello everyone'),
      transcriptionStatus: 'completed',
    );

class _FakeSummariesClient extends SummariesClient {
  _FakeSummariesClient() : super(baseUrl: 'http://unused.invalid');

  final List<String> summarizeCalls = <String>[];

  /// When set, [summarizeDump] records the call and then throws this.
  Exception? summarizeError;

  @override
  Future<void> summarizeDump(String dumpId, {String? template}) async {
    summarizeCalls.add(dumpId);
    final Exception? err = summarizeError;
    if (err != null) throw err;
  }
}

void main() {
  Future<(ProviderContainer, _FakeSummariesClient)> mountWithSummaries(
    WidgetTester tester, {
    bool capability = true,
    List<DumpRow>? rows,
  }) async {
    final _FakeSummariesClient client = _FakeSummariesClient();
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        summariesEnabledProvider.overrideWith((ref) => capability),
        summariesClientProvider.overrideWith(
          (ref) => Future<SummariesClient>.value(client),
        ),
      ],
    );
    if (rows != null) {
      container.read(presentedFixture.notifier).state = AsyncData(
        (
          scopeKey: 'all',
          generation: 2,
          settled: true,
          rows: rows,
          limit: null,
        ),
      );
      await pumpSelection(tester);
    }
    return (container, client);
  }

  Future<void> openSheet(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('dump-more-$id')));
    await pumpSelection(tester);
  }

  testWidgets(
      'regenerate calls the summaries client with the dump id and a 202 '
      'shows the queued snackbar', (tester) async {
    final (_, client) = await mountWithSummaries(
      tester,
      rows: <DumpRow>[transcribedRow('fixture-a'), viewRow('fixture-b')],
    );

    await openSheet(tester, 'fixture-a');
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)),
      findsOneWidget,
      reason: 'a transcribed dump with the capability on offers regenerate',
    );

    await tester
        .tap(find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)));
    await pumpSelection(tester);

    expect(
      client.summarizeCalls,
      <String>['fixture-a'],
      reason: 'the action must post exactly this dump to the server',
    );
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Summary queued'),
      ),
      findsOneWidget,
      reason: 'a 202 must be acknowledged — the summary arrives via sync',
    );
  });

  testWidgets(
      'a 409 not-installed routes the user to Settings by name',
      (tester) async {
    final (_, client) = await mountWithSummaries(
      tester,
      rows: <DumpRow>[transcribedRow('fixture-a'), viewRow('fixture-b')],
    );
    client.summarizeError = const SummarizeConflictException(
      reason: SummarizeConflictReason.notInstalled,
      message: 'Summarizer environment is not installed',
    );

    await openSheet(tester, 'fixture-a');
    await tester
        .tap(find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)));
    await pumpSelection(tester);

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Install AI summaries in Settings first'),
      ),
      findsOneWidget,
      reason: 'the fix for a missing capability is the Settings wizard',
    );
  });

  testWidgets('a 409 no-transcript explains the dump has no transcript yet',
      (tester) async {
    final (_, client) = await mountWithSummaries(
      tester,
      rows: <DumpRow>[transcribedRow('fixture-a'), viewRow('fixture-b')],
    );
    client.summarizeError = const SummarizeConflictException(
      reason: SummarizeConflictReason.noTranscript,
      message: 'Dump has no transcript to summarize',
    );

    await openSheet(tester, 'fixture-a');
    await tester
        .tap(find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)));
    await pumpSelection(tester);

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('This recording has no transcript yet'),
      ),
      findsOneWidget,
      reason: 'server truth wins over a stale local transcript',
    );
  });

  testWidgets('the action is hidden on a dump with no transcript',
      (tester) async {
    final (_, client) = await mountWithSummaries(tester);

    // fixture-a is the stock untranscribed fixture row.
    await openSheet(tester, 'fixture-a');

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)),
      findsNothing,
      reason: 'nothing to summarize — the action can never apply here',
    );
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'the rest of the menu is unchanged',
    );
    expect(client.summarizeCalls, isEmpty);
  });

  testWidgets('the action is hidden while the capability is off',
      (tester) async {
    final (_, client) = await mountWithSummaries(
      tester,
      capability: false,
      rows: <DumpRow>[transcribedRow('fixture-a'), viewRow('fixture-b')],
    );

    await openSheet(tester, 'fixture-a');

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)),
      findsNothing,
      reason: 'while AI summaries are off, none of their UI appears',
    );
    expect(client.summarizeCalls, isEmpty);
  });
}
