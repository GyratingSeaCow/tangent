// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../support/dump_selection_fixture.dart';

Future<void> confirmBatch(WidgetTester t) async {
  await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
  await pumpSelection(t);
  await t.tap(find.byKey(const ValueKey('selection-all')));
  await pumpSelection(t);
  await t.tap(find.byKey(const ValueKey('selection-delete')));
  await pumpSelection(t);
  await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
  await pumpSelection(t);
}

void main() {
  testWidgets('T7-I1 partial retry preserves omitted tickets across failure Cancel and unmount', (t) async {
    final d = CountingDeletion()..result = (replayed: false, items: [
      itemFor('fixture-a', DeleteState.failed, ticket: 'ta'),
      itemFor('fixture-b', DeleteState.failed, ticket: 'tb'),
    ]);
    await mountSelection(t, d);
    await confirmBatch(t);
    final retry = find.byKey(const ValueKey('local-delete-retry'));
    Future<void> openRetry() async {
      await t.ensureVisible(retry); await pumpSelection(t);
      await t.tap(retry); await pumpSelection(t);
    }
    Future<void> submitRetry() async {
      await openRetry();
      await t.tap(find.byKey(const ValueKey('local-delete-confirm')));
      await pumpSelection(t);
    }
    d.retryGate = Completer<Outcome<BulkDeletionResult>>();
    await submitRetry();
    expect(d.retries.single.ticketIds, ['ta','tb']);
    d.retryGate!.complete(Ok((items: [itemFor('fixture-a', DeleteState.deleted, ticket: 'ta')], replayed: true)));
    await pumpSelection(t);
    expect(find.text('Previously recorded result: 1 deleted, 0 failed, 0 skipped'), findsOneWidget);
    expect(find.textContaining('fixture-a: failed'), findsNothing);
    expect(find.textContaining('fixture-b: failed'), findsOneWidget);
    expect(find.text('Pending local deletions (1)'), findsOneWidget);
    d.retryGate = Completer<Outcome<BulkDeletionResult>>();
    await submitRetry(); expect(d.retries.last.ticketIds, ['tb']);
    d.retryGate!.complete(const Fail((code: ProblemCode.denied, message: 'synthetic retry failure')));
    await pumpSelection(t);
    expect(find.textContaining('Local deletion retry failed:'), findsOneWidget);
    await openRetry();
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('local-delete-cancel'))); await pumpSelection(t);
    expect(d.retries, hasLength(2));
    expect(find.textContaining('fixture-b: failed'), findsOneWidget);
    d.retryGate = Completer<Outcome<BulkDeletionResult>>();
    await submitRetry();
    expect(d.retries.last.ticketIds, ['tb']);
    expect(d.retries.map((r) => r.operationId).toSet(), hasLength(3));
    await t.pumpWidget(const SizedBox.shrink());
    d.retryGate!.complete(Ok((items: [itemFor('fixture-b', DeleteState.deleted, ticket: 'tb')], replayed: false)));
    await pumpSelection(t);
    expect(t.takeException(), isNull);
    expect(d.deletes, hasLength(1)); expect(d.retries, hasLength(3));
  });
  testWidgets(
      'mixed totals and component permission failure remain readable at280x640 and2x',
      (t) async {
    t.view.physicalSize = const Size(280, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final d = CountingDeletion()
      ..result = (
        replayed: false,
        items: [
          itemFor('fixture-a', DeleteState.failed, ticket: 'ta'),
          itemFor('fixture-b', DeleteState.deleted),
          itemFor('fixture-skipped', DeleteState.skipped),
        ]
      );
    await mountSelection(t, d, textScale: 2);
    await confirmBatch(t);
    expect(find.text('1 deleted, 1 failed, 1 skipped'), findsOneWidget);
    expect(find.textContaining('metadata: failed (synthetic denied)'),
        findsNWidgets(2),);
    expect(t.takeException(), isNull);
    final retry = find.byKey(const ValueKey('local-delete-retry'));
    await t.ensureVisible(retry);
    await pumpSelection(t);
    await t.tap(retry);
    await pumpSelection(t);
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'exact multiple failed tickets are copied once, retry busy and error remain honest',
      (t) async {
    final gate = Completer<Outcome<BulkDeletionResult>>();
    final d = CountingDeletion()
      ..retryGate = gate
      ..result = (
        replayed: false,
        items: [
          itemFor('fixture-a', DeleteState.failed, ticket: 'ta'),
          itemFor('fixture-b', DeleteState.failed, ticket: 'tb'),
        ]
      );
    await mountSelection(t, d);
    await confirmBatch(t);
    final retryFinder = find.byKey(const ValueKey('local-delete-retry'));
    await t.ensureVisible(retryFinder);
    await pumpSelection(t);
    final retry = t.widget<TextButton>(retryFinder).onPressed!;
    retry();
    retry();
    await pumpSelection(t);
    expect(find.text('Retry deletion of 2 local recordings?'), findsOneWidget);
    final confirm = t
        .widget<FilledButton>(
            find.byKey(const ValueKey('local-delete-confirm')),)
        .onPressed!;
    confirm();
    confirm();
    await pumpSelection(t);
    retry();
    expect(d.retries, hasLength(1));
    expect(d.retries.single.ticketIds, ['ta', 'tb']);
    expect(() => d.retries.single.ticketIds.add('tc'), throwsUnsupportedError);
    expect(d.retries.single.operationId, isNot(d.deletes.single.operationId));
    expect(t.widget<TextButton>(retryFinder).onPressed, isNull);
    gate.complete(const Fail(
        (code: ProblemCode.denied, message: 'synthetic retry denied'),),);
    await pumpSelection(t);
    expect(find.textContaining('Local deletion retry failed:'), findsOneWidget);
    expect(find.text('0 deleted, 2 failed, 0 skipped'), findsOneWidget);
  });
  testWidgets('preview failure has no destructive call or success result',
      (t) async {
    final gate = Completer<Outcome<DeletionPreview>>();
    final d = CountingDeletion()..previewGate = gate;
    await mountSelection(t, d);
    await t.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(t);
    await t.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpSelection(t);
    gate.complete(const Fail((
      code: ProblemCode.unavailable,
      message: 'synthetic storage unavailable'
    ),),);
    await pumpSelection(t);
    expect(find.textContaining('Local deletion failed:'), findsOneWidget);
    expect(d.deletes, isEmpty);
    expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
  });
}
