// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

Future<void> selectDelete(WidgetTester t) async {
  await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
  await pumpSelection(t);
  await t.tap(find.byKey(const ValueKey('selection-delete')));
  await pumpSelection(t);
}

void main() {
  testWidgets('T7-I1 later successful list batch retains the original ticket', (t) async {
    final d = CountingDeletion()..result = (
      items: [itemFor('fixture-a', DeleteState.failed, ticket: 'ticket-a')],
      replayed: false,
    );
    final c = await mountSelection(t, d);
    final route = t.state(find.byType(DumpsListScreen));
    await selectDelete(t);
    await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpSelection(t);
    c.read(eligibilityFixture.notifier).state = {
      'fixture-a': Eligibility.retryOnly, 'fixture-b': Eligibility.eligible,
    };
    d.result = (items: [itemFor('fixture-b', DeleteState.deleted)], replayed: false);
    await pumpSelection(t);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-b')));
    await pumpSelection(t);
    await t.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpSelection(t);
    await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpSelection(t);
    expect(d.deletes, hasLength(2));
    expect(d.deletes.last.targets.map((x) => x.id), ['fixture-b']);
    expect(find.text('1 deleted, 0 failed, 0 skipped'), findsOneWidget);
    expect(find.textContaining('fixture-a: failed'), findsOneWidget,
      reason: 'an unrelated success must not hide unresolved component progress',);
    expect(find.textContaining('audio: removed; metadata: failed'), findsOneWidget);
    final retry = find.byKey(const ValueKey('local-delete-retry'));
    await t.ensureVisible(retry);
    await t.tap(retry);
    await pumpSelection(t);
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await pumpSelection(t);
    expect(d.retries, isEmpty);
    expect(find.textContaining('fixture-a: failed'), findsOneWidget);
    d.retryGate = Completer<Outcome<BulkDeletionResult>>();
    await t.tap(retry);
    await pumpSelection(t);
    final confirm = t.widget<FilledButton>(find.byKey(const ValueKey('local-delete-confirm'))).onPressed!;
    confirm(); confirm();
    await pumpSelection(t);
    expect(d.retries, hasLength(1));
    expect(d.retries.single.ticketIds, ['ticket-a']);
    expect(() => d.retries.single.ticketIds.add('wrong'), throwsUnsupportedError);
    expect(d.deletes.map((r) => r.operationId), isNot(contains(d.retries.single.operationId)));
    d.retryGate!.complete(Ok((items: [itemFor('fixture-a', DeleteState.deleted, ticket: 'ticket-a')], replayed: false)));
    await pumpSelection(t);
    expect(retry, findsNothing);
    expect(find.textContaining('fixture-a: failed'), findsNothing);
    expect(identical(t.state(find.byType(DumpsListScreen)), route), isTrue);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'Cancel has no deletion; captured double Confirm is one exact immutable batch',
      (t) async {
    final d = CountingDeletion()..previewTargets = [targetFor('fixture-a')];
    await mountSelection(t, d);
    await selectDelete(t);
    expect(find.text('Delete 1 local recordings?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await pumpSelection(t);
    expect(d.deletes, isEmpty);
    expect(d.retries, isEmpty);
    await t.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpSelection(t);
    d.previewTargets!.add(targetFor('fixture-b'));
    final confirm = t
        .widget<FilledButton>(
            find.byKey(const ValueKey('local-delete-confirm')),)
        .onPressed!;
    confirm();
    confirm();
    await pumpSelection(t);
    expect(d.deletes, hasLength(1));
    expect(d.deletes.single.targets.map((x) => x.id), ['fixture-a']);
    expect(() => d.deletes.single.targets.add(targetFor('fixture-b')),
        throwsUnsupportedError,);
    expect(find.byType(DumpsListScreen), findsOneWidget);
  });
  testWidgets('obsolete delayed preview is discarded on raw query change',
      (t) async {
    final gate = Completer<Outcome<DeletionPreview>>();
    final d = CountingDeletion()..previewGate = gate;
    final c = await mountSelection(t, d);
    await selectDelete(t);
    c.read(searchQueryProvider.notifier).state = 'new query';
    await pumpSelection(t);
    gate.complete(Ok((targets: [targetFor('fixture-a')])));
    await pumpSelection(t);
    expect(find.byKey(const ValueKey('local-delete-confirm')), findsNothing);
    expect(d.deletes, isEmpty);
  });
  testWidgets(
      'late result never restores changed-scope selection or expands submitted targets',
      (t) async {
    final gate = Completer<Outcome<BulkDeletionResult>>();
    final d = CountingDeletion()..deleteGate = gate;
    final c = await mountSelection(t, d);
    await selectDelete(t);
    await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpSelection(t);
    expect(d.deletes, hasLength(1));
    c.read(presentedFixture.notifier).state = AsyncData((
      scopeKey: 'new',
      generation: 2,
      settled: true,
      rows: [viewRow('fixture-b')],
      limit: 100
    ),);
    await pumpSelection(t);
    gate.complete(Ok((
      items: [itemFor('fixture-a', DeleteState.failed, ticket: 'ticket-a')],
      replayed: false
    ),),);
    await pumpSelection(t);
    expect(d.deletes.single.targets.map((x) => x.id), ['fixture-a']);
    expect(
        t
            .widget<IconButton>(find.byKey(const ValueKey('selection-delete')))
            .onPressed,
        isNull,);
    expect(find.textContaining('1 failed'), findsOneWidget);
  });
  testWidgets(
      'partial result retry is separately confirmed once with exact tickets and new operation ID',
      (t) async {
    final d = CountingDeletion()
      ..result = (
        items: [itemFor('fixture-a', DeleteState.failed, ticket: 'ticket-a')],
        replayed: false
      );
    await mountSelection(t, d);
    await selectDelete(t);
    await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpSelection(t);
    expect(find.textContaining('audio: removed'), findsOneWidget);
    expect(find.textContaining('metadata: failed'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('local-delete-retry')));
    await pumpSelection(t);
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await pumpSelection(t);
    expect(d.retries, isEmpty);
    await t.tap(find.byKey(const ValueKey('local-delete-retry')));
    await pumpSelection(t);
    final confirm = t
        .widget<FilledButton>(
            find.byKey(const ValueKey('local-delete-confirm')),)
        .onPressed!;
    confirm();
    confirm();
    await pumpSelection(t);
    expect(d.retries, hasLength(1));
    expect(d.retries.single.ticketIds, ['ticket-a']);
    expect(d.retries.single.operationId, isNot(d.deletes.single.operationId));
  });
  testWidgets(
      'replayed results are identified rather than a fresh success toast',
      (t) async {
    final d = CountingDeletion()
      ..result =
          (items: [itemFor('fixture-a', DeleteState.deleted)], replayed: true);
    await mountSelection(t, d);
    await selectDelete(t);
    await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpSelection(t);
    expect(find.textContaining('Previously recorded result'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
