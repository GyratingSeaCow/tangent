// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/widgets/dump_picker_sheet.dart';

Dump _dump(String id, String title, DumpMode mode, int seconds) {
  final at = DateTime(2026, 9, 17, 10, 30);
  return Dump(
    id: id,
    createdAt: at,
    updatedAt: at,
    mode: mode,
    durationSeconds: seconds,
    title: title,
    audioPath: '/audio/$id.m4a',
    audioSizeBytes: 2048,
    syncStatus: SyncStatus.localOnly,
  );
}

final _dumps = <Dump>[
  _dump('d1', 'Morning ideas', DumpMode.brainDump, 95),
  _dump('d2', 'Standup meeting', DumpMode.meeting, 620),
  _dump('d3', 'Grocery list', DumpMode.textNote, 0),
];

class _Harness {
  Set<String>? result;
  bool completed = false;
}

Future<_Harness> _openSheet(
  WidgetTester tester, {
  List<Dump>? dumps,
  Set<String> initiallySelected = const <String>{},
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              harness.result = await DumpPickerSheet.show(
                context,
                dumps: dumps ?? _dumps,
                initiallySelected: initiallySelected,
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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists every dump with its mode icon', (tester) async {
    await _openSheet(tester);
    expect(find.text('Morning ideas'), findsOneWidget);
    expect(find.text('Standup meeting'), findsOneWidget);
    expect(find.text('Grocery list'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.groups), findsOneWidget);
    expect(find.byIcon(Icons.notes), findsOneWidget);
    expect(find.textContaining('2026-09-17'), findsNWidgets(3));
  });

  testWidgets('search filters by title, case-insensitively', (tester) async {
    await _openSheet(tester);
    await tester.enterText(
      find.byKey(const ValueKey('dump-picker-search')),
      'MEET',
    );
    await tester.pumpAndSettle();
    expect(find.text('Standup meeting'), findsOneWidget);
    expect(find.text('Morning ideas'), findsNothing);
    expect(find.text('Grocery list'), findsNothing);
    // Clearing the filter restores the full list.
    await tester.enterText(
      find.byKey(const ValueKey('dump-picker-search')),
      '',
    );
    await tester.pumpAndSettle();
    expect(find.text('Morning ideas'), findsOneWidget);
  });

  testWidgets('empty search results show an empty-state message',
      (tester) async {
    await _openSheet(tester);
    await tester.enterText(
      find.byKey(const ValueKey('dump-picker-search')),
      'zzzz',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching recordings'), findsOneWidget);
  });

  testWidgets('selecting two dumps and tapping Add pops exactly those ids',
      (tester) async {
    final harness = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('dump-pick-d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-pick-d3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();
    expect(harness.completed, isTrue);
    expect(harness.result, <String>{'d1', 'd3'});
    expect(find.text('Morning ideas'), findsNothing,
        reason: 'sheet should be dismissed after Add',);
  });

  testWidgets('Cancel pops null', (tester) async {
    final harness = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('dump-pick-d2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-picker-cancel')));
    await tester.pumpAndSettle();
    expect(harness.completed, isTrue);
    expect(harness.result, isNull);
    expect(find.text('Standup meeting'), findsNothing);
  });

  testWidgets('initiallySelected pre-checks the right rows', (tester) async {
    await _openSheet(tester, initiallySelected: {'d2'});
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('dump-pick-d1')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('dump-pick-d2')))
          .value,
      isTrue,
    );
  });

  testWidgets('pre-checked rows survive Add untouched', (tester) async {
    final harness = await _openSheet(tester, initiallySelected: {'d2'});
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();
    expect(harness.result, <String>{'d2'});
  });

  testWidgets('deselecting a pre-checked row removes it from the result',
      (tester) async {
    final harness = await _openSheet(tester, initiallySelected: {'d1', 'd2'});
    await tester.tap(find.byKey(const ValueKey('dump-pick-d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();
    expect(harness.result, <String>{'d2'});
  });

  testWidgets('selections made before filtering survive the filter',
      (tester) async {
    final harness = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('dump-pick-d1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dump-picker-search')),
      'grocery',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-pick-d3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();
    expect(harness.result, <String>{'d1', 'd3'});
  });

  testWidgets('an empty dump list shows the empty state and Add pops empty',
      (tester) async {
    final harness = await _openSheet(tester, dumps: <Dump>[]);
    expect(find.text('No matching recordings'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();
    expect(harness.result, isEmpty);
  });
}
