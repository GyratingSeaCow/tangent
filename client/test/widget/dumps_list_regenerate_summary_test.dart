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
import 'package:drift/native.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
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

/// The server's stock catalogue, custom NOT configured — so the picker
/// shows the four presets and no custom row.
const SummaryTemplates stockCatalogue = SummaryTemplates(
  templates: <SummaryTemplate>[
    SummaryTemplate(id: 'meeting', displayName: 'Meeting'),
    SummaryTemplate(id: 'brain_dump', displayName: 'Brain dump'),
    SummaryTemplate(id: 'lecture', displayName: 'Lecture'),
    SummaryTemplate(id: 'actions_only', displayName: 'Actions only'),
  ],
  customConfigured: false,
);

class _FakeSummariesClient extends SummariesClient {
  _FakeSummariesClient() : super(baseUrl: 'http://unused.invalid');

  final List<String> summarizeCalls = <String>[];

  /// The template sent with each [summarizeDump], in call order.
  final List<String?> templateCalls = <String?>[];

  int listTemplatesCalls = 0;

  /// When set, [summarizeDump] records the call and then throws this.
  Exception? summarizeError;

  @override
  Future<SummaryTemplates> listTemplates() async {
    listTemplatesCalls += 1;
    return stockCatalogue;
  }

  @override
  Future<void> summarizeDump(String dumpId, {String? template}) async {
    summarizeCalls.add(dumpId);
    templateCalls.add(template);
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
    // A real in-memory row store: the 202 mirrors the picked template
    // into the local row so the picker shows it as current straight away.
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final DumpRow r in rows ?? const <DumpRow>[]) {
      await db.into(db.dumps).insert(r);
    }
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        localDbProvider.overrideWithValue(db),
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

  /// Taps ⋮ → Regenerate summary and waits for the template picker. The
  /// picker is a modal bottom sheet: it must never be scrolled in a test
  /// (a drag dismisses it), so the viewport is tall enough for every row.
  Future<void> openTemplatePicker(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpSelection(tester);
    await openSheet(tester, id);
    await tester
        .tap(find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)));
    await pumpSelection(tester);
    expect(
      find.byKey(const ValueKey<String>('summary-template-sheet')),
      findsOneWidget,
      reason: 'regenerate must open the template picker before any POST',
    );
  }

  testWidgets(
      'regenerate opens the template picker; picking Lecture posts the dump '
      'with template=lecture and a 202 shows the queued snackbar',
      (tester) async {
    final (container, client) = await mountWithSummaries(
      tester,
      rows: <DumpRow>[transcribedRow('fixture-a'), viewRow('fixture-b')],
    );

    await openSheet(tester, 'fixture-a');
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.regenerateSummary)),
      findsOneWidget,
      reason: 'a transcribed dump with the capability on offers regenerate',
    );
    // Close it again; the picker helper reopens with a tall viewport.
    await tester.tapAt(const Offset(5, 5));
    await pumpSelection(tester);

    await openTemplatePicker(tester, 'fixture-a');
    expect(client.listTemplatesCalls, 1);
    expect(
      client.summarizeCalls,
      isEmpty,
      reason: 'nothing is posted until a template is picked',
    );
    // Custom is not configured on this server, so it is not offered.
    expect(
      find.byKey(const ValueKey<String>('summary-template-custom')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('summary-template-lecture')));
    await pumpSelection(tester);

    expect(
      client.summarizeCalls,
      <String>['fixture-a'],
      reason: 'the action must post exactly this dump to the server',
    );
    expect(
      client.templateCalls,
      <String?>['lecture'],
      reason: 'the picked template rides on the POST',
    );
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Summary queued'),
      ),
      findsOneWidget,
      reason: 'a 202 must be acknowledged — the summary arrives via sync',
    );
    // The pick sticks locally the moment the server accepts — a user who
    // reopens the picker before the summary syncs down sees it ticked.
    final DumpRow? mirrored =
        await container.read(localDbProvider).getDump('fixture-a');
    expect(mirrored?.summaryTemplate, 'lecture');
    expect(mirrored?.syncDirty ?? false, isFalse,
          reason: 'server-held value; must not be pushed back',
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

    await openTemplatePicker(tester, 'fixture-a');
    await tester.tap(find.byKey(const ValueKey<String>('summary-template-meeting')));
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

    await openTemplatePicker(tester, 'fixture-a');
    await tester.tap(find.byKey(const ValueKey<String>('summary-template-meeting')));
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
