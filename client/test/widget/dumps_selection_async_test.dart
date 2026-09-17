// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

void main() {
  testWidgets(
      'unsettled and eligibility errors disable stale delete callback; reappearance keeps selection',
      (t) async {
    final d = CountingDeletion();
    final c = await mountSelection(t, d);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(t);
    final delete = t
        .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
        .onPressed!;
    final current = c.read(presentedFixture);
    c.read(presentedFixture.notifier).state =
        const AsyncLoading<PresentedDumpResults>().copyWithPrevious(current);
    await pumpSelection(t);
    expect(
        t
            .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
            .onPressed,
        isNull,);
    delete();
    await pumpSelection(t);
    expect(d.previews, isEmpty);
    c.read(presentedFixture.notifier).state = current;
    await pumpSelection(t);
    expect(find.text('1 selected'), findsOneWidget);
    c.read(eligibilityFixture.notifier).state = {};
    await pumpSelection(t);
    delete();
    await pumpSelection(t);
    expect(d.previews, isEmpty);
    c.read(presentedFixture.notifier).state = AsyncError<PresentedDumpResults>(
            StateError('synthetic results failed'), StackTrace.current,)
        .copyWithPrevious(current);
    await pumpSelection(t);
    expect(find.textContaining('Results unavailable'), findsOneWidget);
    expect(d.deletes, isEmpty);
  });
  testWidgets(
      'older presented generation cannot render old rows or submit current selection',
      (t) async {
    final d = CountingDeletion();
    final c = await mountSelection(t, d);
    c.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'new',
      generation: 3,
      settled: true,
      rows: [viewRow('fixture-b')],
      limit: 100
    ),);
    await pumpSelection(t);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-b')));
    await pumpSelection(t);
    c.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'old',
      generation: 2,
      settled: true,
      rows: [viewRow('fixture-a')],
      limit: 100
    ),);
    await pumpSelection(t);
    expect(find.byKey(const ValueKey('dump-row-fixture-a')), findsNothing);
    expect(
        t
            .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
            .onPressed,
        isNull,);
    expect(d.previews, isEmpty);
  });
  for (final change in [
    'mode',
    'transcript',
    'query',
    'generation',
    'cancel',
    'unmount',
  ]) {
    testWidgets('delayed preview cannot open after $change', (t) async {
      final gate = Completer<Outcome<DeletionPreview>>();
      final d = CountingDeletion()..previewGate = gate;
      final c = await mountSelection(t, d);
      await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
      await pumpSelection(t);
      await t.tap(find.byKey(const ValueKey('selection-delete')));
      await pumpSelection(t);
      expect(d.previews, hasLength(1));
      switch (change) {
        case 'mode':
          c.read(dumpModeFilterProvider.notifier).state =
              DumpModeFilter.meeting;
        case 'transcript':
          c.read(transcriptFilterProvider.notifier).state =
              TranscriptFilter.failed;
        case 'query':
          c.read(searchQueryProvider.notifier).state = 'raw query';
        case 'generation':
          c.read(presentedFixture.notifier).state = AsyncData((
            scopeKey: 'all',
            generation: 2,
            settled: false,
            rows: [],
            limit: null
          ),);
        case 'cancel':
          await t.tap(find.byKey(const ValueKey('selection-cancel')));
        case 'unmount':
          await t.pumpWidget(const SizedBox.shrink());
      }
      await pumpSelection(t);
      gate.complete(Ok((targets: [targetFor('fixture-a')])));
      await pumpSelection(t);
      expect(find.byKey(const ValueKey('local-delete-confirm')), findsNothing);
      expect(d.deletes, isEmpty);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'confirmed batch continues on unmount and captured callback is inert after disposal',
      (t) async {
    final gate = Completer<Outcome<BulkDeletionResult>>();
    final d = CountingDeletion()..deleteGate = gate;
    await mountSelection(t, d);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(t);
    final submit = t
        .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
        .onPressed!;
    submit();
    await pumpSelection(t);
    final confirm = t
        .widget<FilledButton>(
            find.byKey(const ValueKey('local-delete-confirm')),)
        .onPressed!;
    confirm();
    await pumpSelection(t);
    submit();
    expect(d.deletes, hasLength(1));
    await t.pumpWidget(const SizedBox.shrink());
    await pumpSelection(t);
    gate.complete(Ok(
        (items: [itemFor('fixture-a', DeleteState.deleted)], replayed: false),),);
    await pumpSelection(t);
    submit();
    confirm();
    await pumpSelection(t);
    expect(d.deletes, hasLength(1));
    expect(t.takeException(), isNull);
  });
}
