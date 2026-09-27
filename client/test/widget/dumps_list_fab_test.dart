// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';

/// T2: the dumps list carries a blue `+` FAB (bottom-right) whose result
/// depends on the active mode filter — a concrete [DumpsCreateAction] when a
/// mode chip is active, or a two-option bottom sheet (Brain Dump | Text
/// Note — meeting capture is removed, M1) under the All filter.
/// The screen pops itself with the chosen action; home consumes it.

void _useTaskViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

List<Override> _overrides() => [
      deletionEligibilityProvider.overrideWith(
        (_) => Stream.value(const <String, Eligibility>{}),
      ),
      dumpsProvider.overrideWith((_) => Stream.value(const <DumpRow>[])),
    ];

void _registerUnmount(WidgetTester tester) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

/// Pushes the dumps list onto a host navigator with a typed result slot so
/// tests can observe exactly what the screen pops with.
class _PopProbe {
  DumpsCreateAction? result;
  bool completed = false;
}

Future<_PopProbe> _pushList(WidgetTester tester) async {
  final probe = _PopProbe();
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-dumps'),
                onPressed: () {
                  unawaited(
                    Navigator.of(context)
                        .push<DumpsCreateAction?>(
                          MaterialPageRoute<DumpsCreateAction?>(
                            builder: (_) => const DumpsListScreen(),
                          ),
                        )
                        .then((value) {
                      probe.result = value;
                      probe.completed = true;
                    }),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _registerUnmount(tester);
  await tester.tap(find.byKey(const ValueKey('open-dumps')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _pumpData(tester);
  return probe;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'dumps list shows an Add FAB in primary color at the bottom-right',
      (tester) async {
    _useTaskViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    _registerUnmount(tester);
    await _pumpData(tester);

    final fabFinder = find.byType(FloatingActionButton);
    expect(fabFinder, findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(fabFinder);
    final colors = Theme.of(tester.element(fabFinder)).colorScheme;
    expect(fab.backgroundColor, colors.primary,
        reason: 'the bubble must use the app blue (colorScheme.primary)',);
    expect(fab.tooltip, 'Add');
    expect(
      find.descendant(of: fabFinder, matching: find.byIcon(Icons.add)),
      findsOneWidget,
    );

    // Default FloatingActionButtonLocation.endFloat: bottom-right quadrant.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.floatingActionButtonLocation, isNull,
        reason: 'default (endFloat) keeps the bubble bottom-right',);
    final rect = tester.getRect(fabFinder);
    expect(rect.center.dx, greaterThan(1080 / 2));
    expect(rect.center.dy, greaterThan(2340 / 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Text Note filter active: FAB pops with DumpsCreateAction.textNote',
      (tester) async {
    _useTaskViewport(tester);
    final probe = await _pushList(tester);

    // Filters are dropdowns now: open the menu, then tap the same key.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-textNote')));
    await _pumpData(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(probe.completed, isTrue);
    expect(probe.result, DumpsCreateAction.textNote);
    expect(find.byType(DumpsListScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Brain Dump filter active: FAB pops with DumpsCreateAction.brainDump',
      (tester) async {
    _useTaskViewport(tester);
    final probe = await _pushList(tester);

    // Filters are dropdowns now: open the menu, then tap the same key.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-brainDump')));
    await _pumpData(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(probe.completed, isTrue);
    expect(probe.result, DumpsCreateAction.brainDump);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'All filter: FAB opens a sheet offering exactly Brain Dump and '
      'Text Note — meeting capture is gone (M1)', (tester) async {
    _useTaskViewport(tester);
    final probe = await _pushList(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(probe.completed, isFalse,
        reason: 'under the All filter the FAB asks before popping',);
    final textNoteOption = find.byKey(const ValueKey('create-option-textNote'));
    final brainDumpOption =
        find.byKey(const ValueKey('create-option-brainDump'));
    expect(textNoteOption, findsOneWidget);
    expect(brainDumpOption, findsOneWidget);
    // M1: create surfaces offer exactly {brain dump, note} — two ListTiles,
    // no Meeting option by key or label.
    expect(
      find.byKey(const ValueKey('create-option-meeting')),
      findsNothing,
      reason: 'meeting capture is removed from every create surface',
    );
    expect(find.text('Meeting'), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(
      find.descendant(of: textNoteOption, matching: find.text('Text Note')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: brainDumpOption, matching: find.text('Brain Dump')),
      findsOneWidget,
    );

    await tester.tap(brainDumpOption);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(probe.completed, isTrue);
    expect(probe.result, DumpsCreateAction.brainDump);
    expect(find.byType(DumpsListScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Meeting filter active: FAB falls back to the create sheet instead of '
      'starting a new meeting recording', (tester) async {
    _useTaskViewport(tester);
    final probe = await _pushList(tester);

    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-meeting')));
    await _pumpData(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(probe.completed, isFalse,
        reason: 'no direct meeting creation exists anymore',);
    expect(
      find.byKey(const ValueKey('create-option-meeting')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('create-option-textNote')),
        findsOneWidget,);
    expect(find.byKey(const ValueKey('create-option-brainDump')),
        findsOneWidget,);
    expect(tester.takeException(), isNull);
  });
}