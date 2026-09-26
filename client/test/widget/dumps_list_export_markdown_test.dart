// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Timestamped Markdown export (v1.16.0 spec §4 / §5): the '⋮ > Export
// Markdown' action on the recordings list. Present for a transcribed
// recording, ABSENT — not disabled — for an untranscribed one (there is
// nothing to export). Picking it calls the one export provider with that row.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/markdown_export.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

DumpRow _transcribedRow(String id) => viewRow(id).copyWith(
      transcript: const Value<String?>('[00:00] Alice: hello everyone'),
      transcriptionStatus: 'completed',
    );

DumpRow _blankTranscriptRow(String id) => viewRow(id).copyWith(
      transcript: const Value<String?>('   '),
      transcriptionStatus: 'completed',
    );

void main() {
  final Finder exportMarkdown =
      find.byKey(ItemActionSheet.keyFor(ItemAction.exportMarkdown));

  Future<ProviderContainer> mountRows(
    WidgetTester tester,
    List<DumpRow> rows, {
    List<Override> extraOverrides = const <Override>[],
  }) async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        localDbProvider.overrideWithValue(db),
        ...extraOverrides,
      ],
    );
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
    return container;
  }

  Future<void> openSheet(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('dump-more-$id')));
    await pumpSelection(tester);
  }

  testWidgets('a transcribed recording offers Export Markdown after Move',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await mountRows(tester, <DumpRow>[_transcribedRow('fixture-a')]);

    await openSheet(tester, 'fixture-a');
    expect(exportMarkdown, findsOneWidget);
    expect(
      find.descendant(
        of: exportMarkdown,
        matching: find.text('Export Markdown'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: exportMarkdown,
        matching: find.byIcon(Icons.description),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<ListTile>(exportMarkdown).enabled,
      isTrue,
      reason: 'offered rows are never greyed — absence is the only gate',
    );
    final double moveY = tester
        .getTopLeft(find.byKey(ItemActionSheet.keyFor(ItemAction.move)))
        .dy;
    final double selectY = tester
        .getTopLeft(find.byKey(ItemActionSheet.keyFor(ItemAction.select)))
        .dy;
    final double exportY = tester.getTopLeft(exportMarkdown).dy;
    expect(exportY, greaterThan(moveY));
    expect(exportY, lessThan(selectY), reason: 'sits between Move and Select');
  });

  testWidgets('an untranscribed (or blank) recording gets no such tile',
      (tester) async {
    await mountRows(
      tester,
      <DumpRow>[viewRow('fixture-a'), _blankTranscriptRow('fixture-b')],
    );

    await openSheet(tester, 'fixture-a');
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'the sheet itself opened',
    );
    expect(exportMarkdown, findsNothing, reason: 'absent, not disabled');
    await tester.tapAt(const Offset(5, 5));
    await pumpSelection(tester);

    await openSheet(tester, 'fixture-b');
    expect(exportMarkdown, findsNothing, reason: 'whitespace is no transcript');
  });

  testWidgets('picking Export Markdown calls the provider with that row',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final List<DumpRow> exported = <DumpRow>[];
    await mountRows(
      tester,
      <DumpRow>[_transcribedRow('fixture-a'), _transcribedRow('fixture-b')],
      extraOverrides: <Override>[
        exportMarkdownProvider.overrideWithValue((DumpRow row) async {
          exported.add(row);
          return const MarkdownExportOutcome(
            path: '/exports/fixture.md',
            opened: true,
          );
        }),
      ],
    );

    await openSheet(tester, 'fixture-b');
    await tester.tap(exportMarkdown);
    await pumpSelection(tester);
    await pumpSelection(tester);

    expect(
      exported.map((r) => r.id),
      ['fixture-b'],
      reason: 'exactly the row whose ⋮ was opened, once',
    );
    expect(
      find.text('Exported to /exports/fixture.md'),
      findsOneWidget,
      reason: 'a desktop outcome tells the user where the file went',
    );
  });
}
