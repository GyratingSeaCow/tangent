// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Speaker naming (v1.15.0 spec §4.1): the '⋮ > Name speakers' action on
// the recordings list. Absent — not disabled — when the row's transcript
// has no `## Speaker N` headings: there is nothing to name, so nothing is
// offered (dumps-ui-conventions). Picking it opens the Name-speakers sheet.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

const String _diarized = '## Speaker 1\n'
    'Ended up getting fired and then hired again.\n'
    '\n'
    '## Speaker 2\n'
    'That is quite the arc.\n';

DumpRow _diarizedRow(String id) => viewRow(id).copyWith(
      transcript: const Value<String?>(_diarized),
      transcriptionStatus: 'completed',
    );

DumpRow _plainRow(String id) => viewRow(id).copyWith(
      transcript: const Value<String?>('[00:00] Alice: hello everyone'),
      transcriptionStatus: 'completed',
    );

void main() {
  final Finder nameSpeakers =
      find.byKey(ItemActionSheet.keyFor(ItemAction.nameSpeakers));

  Future<ProviderContainer> mountRows(
    WidgetTester tester,
    List<DumpRow> rows,
  ) async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[localDbProvider.overrideWithValue(db)],
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

  testWidgets('a diarized row offers Name speakers directly after Rename',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await mountRows(tester, <DumpRow>[_diarizedRow('fixture-a')]);

    await openSheet(tester, 'fixture-a');
    expect(nameSpeakers, findsOneWidget);
    expect(
      find.descendant(of: nameSpeakers, matching: find.text('Name speakers')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: nameSpeakers,
        matching: find.byIcon(Icons.record_voice_over),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<ListTile>(nameSpeakers).enabled,
      isTrue,
      reason: 'offered rows are never greyed — absence is the only gate',
    );
    final double renameY = tester
        .getTopLeft(find.byKey(ItemActionSheet.keyFor(ItemAction.rename)))
        .dy;
    final double moveY = tester
        .getTopLeft(find.byKey(ItemActionSheet.keyFor(ItemAction.move)))
        .dy;
    final double nameY = tester.getTopLeft(nameSpeakers).dy;
    expect(nameY, greaterThan(renameY));
    expect(nameY, lessThan(moveY), reason: 'sits between Rename and Move');
  });

  testWidgets('a transcript without speaker headings gets no such tile',
      (tester) async {
    await mountRows(
      tester,
      <DumpRow>[_plainRow('fixture-a'), viewRow('fixture-b')],
    );

    await openSheet(tester, 'fixture-a');
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
    );
    expect(nameSpeakers, findsNothing, reason: 'absent, not disabled');
    await tester.tapAt(const Offset(5, 5));
    await pumpSelection(tester);

    await openSheet(tester, 'fixture-b');
    expect(nameSpeakers, findsNothing, reason: 'no transcript at all');
  });

  testWidgets('picking Name speakers opens the sheet for that row',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await mountRows(tester, <DumpRow>[_diarizedRow('fixture-a')]);

    await openSheet(tester, 'fixture-a');
    await tester.tap(nameSpeakers);
    await pumpSelection(tester);
    await pumpSelection(tester);

    expect(find.byKey(const ValueKey('name-speakers-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('speaker-label-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('speaker-label-2')), findsOneWidget);
  });
}
