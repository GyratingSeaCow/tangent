// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' show SemanticsFlag;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

void main() {
  for (final width in [360.0, 280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'selection and confirmation accessible at ${width}x640 scale $scale',
          (t) async {
        t.view.physicalSize = Size(width, 640);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final semantics = t.ensureSemantics();
        try {
          await mountSelection(t, CountingDeletion(), textScale: scale);
          expect(t.takeException(), isNull);
          await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
          await pumpSelection(t);
          expect(t.takeException(), isNull);
          final bubble = find.byKey(const ValueKey('dump-select-fixture-a'));
          expect(t.getSize(bubble).width, greaterThanOrEqualTo(48));
          expect(t.getSize(bubble).height, greaterThanOrEqualTo(48));
          expect(
              t.getSemantics(bubble).hasFlag(SemanticsFlag.isChecked), isTrue,);
          final all = find.byKey(const ValueKey('selection-all'));
          expect(t.getSemantics(all).hasFlag(SemanticsFlag.isCheckStateMixed),
              isTrue,);
          await t.tap(all);
          await pumpSelection(t);
          expect(t.getSemantics(all).hasFlag(SemanticsFlag.isChecked), isTrue);
          await t.tap(all);
          await pumpSelection(t);
          expect(t.getSemantics(all).hasFlag(SemanticsFlag.isChecked), isFalse);
          expect(
              t
                  .widget<IconButton>(
                      find.byKey(const ValueKey('selection-delete')),)
                  .onPressed,
              isNull,);
          await t.tap(bubble);
          await pumpSelection(t);
          await t.tap(find.byKey(const ValueKey('selection-delete')));
          await pumpSelection(t);
          expect(t.takeException(), isNull);
          expect(find.textContaining('Server copies are not deleted'),
              findsOneWidget,);
          expect(
              t
                  .widget<TextButton>(
                      find.byKey(const ValueKey('local-delete-cancel')),)
                  .autofocus,
              isTrue,);
          await t.tap(find.byKey(const ValueKey('local-delete-cancel')));
          await pumpSelection(t);
          expect(t.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
  testWidgets(
      'offscreen all excludes hidden and disabled; changes prune, arrivals never enroll',
      (t) async {
    final d = CountingDeletion();
    final c = await mountSelection(t, d);
    final rows = List.generate(100, (i) => viewRow('fixture-$i'));
    c.read(eligibilityFixture.notifier).state = {
      for (final r in rows) r.id: Eligibility.eligible,
      'fixture-1': Eligibility.nonterminal,
      'hidden': Eligibility.eligible,
    };
    c.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'search',
      generation: 2,
      settled: true,
      rows: rows,
      limit: 100
    ),);
    await pumpSelection(t);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-0')));
    await pumpSelection(t);
    expect(find.byKey(const ValueKey('dump-row-fixture-99')), findsNothing);
    final disabled = find.byKey(const ValueKey('dump-select-fixture-1'));
    expect(t.widget<Checkbox>(disabled).onChanged, isNull);
    expect(t.widget<Checkbox>(disabled).semanticLabel,
        contains('Transcription in progress'),);
    await t.tap(find.byKey(const ValueKey('selection-all')));
    await pumpSelection(t);
    expect(find.text('99 selected'), findsOneWidget);
    expect(find.textContaining('100-candidate limit'), findsOneWidget);
    c.read(eligibilityFixture.notifier).state = {
      ...c.read(eligibilityFixture),
      'arrival': Eligibility.eligible,
      'fixture-2': Eligibility.syncing,
    };
    c.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'search',
      generation: 2,
      settled: true,
      rows: [viewRow('arrival'), ...rows.skip(1).toList().reversed],
      limit: 100
    ),);
    await pumpSelection(t);
    expect(find.text('97 selected'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpSelection(t);
    expect(d.previews.single, hasLength(97));
    expect(d.previews.single, isNot(contains('arrival')));
    expect(d.previews.single, isNot(contains('hidden')));
  });
  testWidgets(
      'Back cancels selection first and next Back preserves normal route pop',
      (t) async {
    final d = CountingDeletion();
    await mountSelection(t, d, nestedRoute: true);
    await pumpSelection(t);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(t);
    final navigator = Navigator.of(t.element(find.byType(DumpsListScreen)));
    await navigator.maybePop();
    await pumpSelection(t);
    expect(find.byType(DumpsListScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-cancel')), findsNothing);
    await navigator.maybePop();
    await pumpSelection(t);
    await pumpSelection(t);
    expect(find.text('Fixture home'), findsOneWidget);
    expect(d.deletes, isEmpty);
  });
}
