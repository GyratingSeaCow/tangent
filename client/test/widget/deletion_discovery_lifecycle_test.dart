// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/storage_fixture.dart';
import 'deletion_restart_recovery_test.dart' show RecoveryHarness;

Future<BoundRecording> seedPending(
    WidgetTester tester, RecoveryHarness h,) async {
  return (await tester.runAsync(() async {
    final a = await h.f.seed('fixture-discovery-pending');
    final preview = requireOk(await h.deletion.preview({a.key.dumpId}));
    requireOk(await h.deletion.deleteConfirmed(
        (operationId: 'fixture-original', targets: preview.targets),),);
    await h.owners!.mutations.drain();
    await h.f.reopen();
    await h.freshOwners();
    return a;
  }))!;
}

Future<GlobalKey<NavigatorState>> openRecording(
    WidgetTester tester, RecoveryHarness h, BoundRecording a,) async {
  final navigator = await h.mountList(tester);
  final row = find.byKey(ValueKey('dump-row-${a.key.dumpId}'));
  await pumpBoundUntil(tester, () => row.evaluate().isNotEmpty);
  await tester.tap(row);
  await pumpBoundUntil(
      tester,
      () =>
          h.deletion.firstPreviewValue != null &&
          find
              .byKey(ValueKey('title-editor-${a.key.dumpId}'))
              .evaluate()
              .isNotEmpty,);
  return navigator;
}

void main() {
  testWidgets(
      'I1-I1 captured discovery recheck is inert during admission and after disposal',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final a = await seedPending(tester, h);
    h.deletion.previewResponse = (_, actual) => const Fail(
        (code: ProblemCode.unavailable, message: 'synthetic unavailable'),);
    final navigator = await openRecording(tester, h, a);
    await pumpBoundUntil(tester,
        () => find.text('Check pending deletion again').evaluate().isNotEmpty,);
    final check = tester
        .widget<TextButton>(
            find.widgetWithText(TextButton, 'Check pending deletion again'),)
        .onPressed!;
    h.deletion.previewResponse = null;
    check();
    await pumpBoundUntil(
        tester, () => find.byTooltip('Retry deletion').evaluate().isNotEmpty,);
    h.deletion.beforePreview = (index) async {
      if (index == 2) await gate.future;
    };
    await tester.tap(find.byTooltip('Retry deletion'));
    await pumpBoundUntil(tester, () => h.deletion.previews.length >= 3);
    check();
    check();
    await tester.pump();
    expect(h.deletion.previews, hasLength(3));
    expect(h.backend.calls, hasLength(2));
    expect(h.deletion.retries, isEmpty);
    gate.complete();
    await pumpBoundUntil(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
    await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    check();
    check();
    await tester.pump();
    expect(h.deletion.previews, hasLength(3));
    await disposeBoundWidget(tester, h.owners!);
    expect(tester.takeException(), isNull);
  });
  testWidgets('I1-I1 late entry preview cannot clear a newer failed action',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final a = await seedPending(tester, h);
    h.deletion.firstPreviewGate = Completer<void>();
    h.deletion.previewResponse = (index, actual) => index == 1
        ? const Fail((
            code: ProblemCode.unavailable,
            message: 'synthetic newer preview failure'
          ),)
        : actual;
    await openRecording(tester, h, a);
    await tester.tap(find.byTooltip('Delete'));
    await pumpBoundUntil(
        tester,
        () => find
            .textContaining('Local deletion could not continue.')
            .evaluate()
            .isNotEmpty,);
    expect(find.byType(AlertDialog), findsNothing);
    h.deletion.firstPreviewGate!.complete();
    await pumpBoundUntil(tester, () => h.deletion.returnedPreviews == 2);
    expect(find.textContaining('Local deletion could not continue.'),
        findsOneWidget,);
    expect(find.byTooltip('Retry deletion'), findsNothing);
    expect(h.backend.calls, hasLength(2));
    expect(h.deletion.retries, isEmpty);
    expect(h.deletion.deletes, isEmpty);
    await tester.tap(find.text('Check pending deletion again'));
    await pumpBoundUntil(
        tester, () => find.byTooltip('Retry deletion').evaluate().isNotEmpty,);
    expect(find.textContaining('audio: unknown; metadata: unknown'),
        findsOneWidget,);
    expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
    await disposeBoundWidget(tester, h.owners!);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'I1-I1 disposal before entry preview ignores late identity and captured callback',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final a = await seedPending(tester, h);
    h.deletion.firstPreviewGate = Completer<void>();
    final navigator = await openRecording(tester, h, a);
    final state = tester.state(find.byType(DumpDetailScreen));
    final top = tester
        .widget<IconButton>(find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Delete'),)
        .onPressed!;
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(state.mounted, isFalse);
    top();
    top();
    h.deletion.firstPreviewGate!.complete();
    await pumpBoundUntil(tester, () => h.deletion.returnedPreviews == 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.deletion.previews, hasLength(1));
    expect(h.deletion.deletes, isEmpty);
    expect(h.deletion.retries, isEmpty);
    expect(h.backend.calls, hasLength(2));
    expect(
        (await tester.runAsync(h.f.db.pendingLocalDeletions))!, hasLength(1),);
    await disposeBoundWidget(tester, h.owners!);
    expect(tester.takeException(), isNull);
  });

  for (final fault in [
    'unavailable',
    'missing target',
    'wrong target',
    'missing ticket',
    'missing binding',
  ]) {
    testWidgets(
        'I1-I1 $fault preview fails closed and explicit recheck recovers',
        (tester) async {
      final h = RecoveryHarness();
      await tester.runAsync(h.freshOwners);
      addTearDown(() => h.close(tester));
      final a = await seedPending(tester, h);
      h.deletion.previewResponse = (_, actual) {
        if (fault == 'unavailable') {
          return const Fail((
            code: ProblemCode.denied,
            message: 'synthetic permission denial'
          ),);
        }
        if (fault == 'missing target') {
          return const Ok((targets: <DeleteTarget>[]));
        }
        final target = requireOk(actual).targets.single;
        return Ok((
          targets: <DeleteTarget>[
            (
              id: fault == 'wrong target' ? 'fixture-other' : target.id,
              binding: fault == 'missing binding' ? null : target.binding,
              title: target.title,
              eligibility: target.eligibility,
              retryTicketId:
                  fault == 'missing ticket' ? null : target.retryTicketId,
            ),
          ]
        ),);
      };
      await openRecording(tester, h, a);
      await pumpBoundUntil(
          tester,
          () => find
              .textContaining('Could not check pending local deletion.')
              .evaluate()
              .isNotEmpty,);
      expect(find.byKey(const ValueKey('local-delete-retry')), findsNothing);
      expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
      await tester.tap(find.byTooltip('Delete'));
      await pumpBoundUntil(
          tester,
          () => find
              .textContaining('Local deletion could not continue.')
              .evaluate()
              .isNotEmpty,);
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.deletion.deletes, isEmpty);
      expect(h.deletion.retries, isEmpty);
      expect(h.backend.calls, hasLength(2));
      h.deletion.previewResponse = null;
      await tester.tap(find.text('Check pending deletion again'));
      await pumpBoundUntil(
          tester, () => find.byTooltip('Retry deletion').evaluate().isNotEmpty,);
      expect(find.textContaining('audio: unknown; metadata: unknown'),
          findsOneWidget,);
      expect(h.backend.calls, hasLength(2));
      await disposeBoundWidget(tester, h.owners!);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'I1-I1 ticket appearing after ordinary consent requires separate retry consent',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final a = (await tester.runAsync(() => h.f.seed('fixture-racing-ticket')))!;
    h.deletion.beforePreview = (index) async {
      if (index != 2) return;
      // Another legitimate owner completes a partial operation after our player
      // closes. The UI must not reuse its ordinary confirmation for this ticket.
      final other = DefaultLocalDeletionService(
          db: h.f.db, backend: h.backend, mutations: h.owners!.mutations,);
      final preview = requireOk(await other.preview({a.key.dumpId}));
      requireOk(await other.deleteConfirmed(
          (operationId: 'fixture-other-owner', targets: preview.targets),),);
    };
    await openRecording(tester, h, a);
    await pumpBoundUntil(tester, () => h.players.single.loaded);
    await tester.tap(find.byTooltip('Delete'));
    await pumpBoundUntil(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
    expect(find.text('Delete 1 local recordings?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpBoundUntil(
        tester,
        () => find
            .textContaining('confirm it separately.')
            .evaluate()
            .isNotEmpty,);
    expect(find.byTooltip('Retry deletion'), findsOneWidget);
    expect(h.deletion.deletes, isEmpty);
    expect(h.deletion.retries, isEmpty);
    expect(h.backend.calls, hasLength(2));
    expect(
        (await tester.runAsync(h.f.db.pendingLocalDeletions))!
            .single
            .operationId,
        'fixture-other-owner',);
    await tester.tap(find.byTooltip('Retry deletion'));
    await pumpBoundUntil(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await tester.pumpAndSettle();
    expect(h.deletion.retries, isEmpty);
    expect(h.backend.calls, hasLength(2));
    await disposeBoundWidget(tester, h.owners!);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'I1-I1 preview failure before consent keeps the existing playback owner',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final a =
        (await tester.runAsync(() => h.f.seed('fixture-discovery-player')))!;
    h.deletion.previewResponse = (index, actual) => index == 1
        ? const Fail((
            code: ProblemCode.unavailable,
            message: 'synthetic preview unavailable'
          ),)
        : actual;
    await h.mountList(tester);
    final row = find.byKey(ValueKey('dump-row-${a.key.dumpId}'));
    await pumpBoundUntil(tester, () => row.evaluate().isNotEmpty);
    await tester.tap(row);
    await pumpBoundUntil(
        tester,
        () =>
            h.players.isNotEmpty &&
            h.players.last.loaded &&
            h.deletion.returnedPreviews == 1,);
    await tester.tap(find.byTooltip('Delete'));
    await pumpBoundUntil(tester,
        () => find.textContaining('Delete failed:').evaluate().isNotEmpty,);
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.backend.calls, isEmpty);
    expect(h.deletion.deletes, isEmpty);
    expect(h.deletion.retries, isEmpty);
    expect(h.players, hasLength(1));
    expect(h.players.single.closes, 0);
    expect(find.text('Retry playback'), findsNothing);
    await tester.tap(find.byTooltip('Play recording'));
    await tester.pump();
    expect(h.players.single.plays, 1);
    await disposeBoundWidget(tester, h.owners!);
    expect(h.players.single.closes, 1);
    expect(tester.takeException(), isNull);
  });
}
