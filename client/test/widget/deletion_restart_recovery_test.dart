// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/scripted_storage_backend.dart';
import '../support/storage_fixture.dart';
import 'dump_detail_lifetime_test.dart' show GatePlayer, mount;

class RecoveryBackend extends ScriptedStorageBackend {
  final calls = <({
    BoundRecording binding,
    RecordingComponent component,
    String operationId
  })>[];
  @override
  IoOperation<ComponentResult> deleteComponent(BoundRecording binding,
      RecordingComponent component, String operationId,) {
    calls.add(
        (binding: binding, component: component, operationId: operationId),);
    return super.deleteComponent(binding, component, operationId);
  }
}

class RecoveryDeletion extends DefaultLocalDeletionService {
  RecoveryDeletion(
      {required super.db, required super.backend, required super.mutations,});
  final deletes = <ConfirmedDeletion>[], retries = <ConfirmedDeletionRetry>[];
  final previews = <Set<String>>[];
  int returnedPreviews = 0;
  Completer<void>? firstPreviewGate;
  Outcome<DeletionPreview>? firstPreviewValue;
  Outcome<DeletionPreview> Function(int, Outcome<DeletionPreview>)?
      previewResponse;
  Future<void> Function(int)? beforePreview;
  Completer<void>? originalResultGate;
  bool originalComputed = false, originalReturned = false;
  @override
  Future<Outcome<DeletionPreview>> preview(Set<String> ids) async {
    final index = previews.length;
    previews.add(Set.unmodifiable(ids));
    await beforePreview?.call(index);
    final actual = await super.preview(ids);
    final result = previewResponse?.call(index, actual) ?? actual;
    if (index == 0) {
      firstPreviewValue = result;
      await firstPreviewGate?.future;
    }
    returnedPreviews++;
    return result;
  }

  @override
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(
      ConfirmedDeletion request,) async {
    deletes.add(request);
    final result = await super.deleteConfirmed(request);
    originalComputed = true;
    await originalResultGate?.future;
    originalReturned = true;
    return result;
  }

  @override
  Future<Outcome<BulkDeletionResult>> retryConfirmed(
      ConfirmedDeletionRetry request,) {
    retries.add(request);
    return super.retryConfirmed(request);
  }
}

class RecoveryHarness {
  final f = StorageFixture.create();
  final backend = RecoveryBackend()..metadataDeleteFails = true;
  BoundServiceFixture? owners;
  late SqliteStorageCatalog catalog;
  late RecoveryDeletion deletion;
  final players = <GatePlayer>[];
  Future<void> freshOwners() async {
    final bound = await createBoundServiceFixture(f.db,
        backend: backend, registerDrain: false,);
    owners = bound;
    var counter = 0;
    catalog = SqliteStorageCatalog(
        db: f.db,
        backend: backend,
        mutations: bound.mutations,
        stagingDirectory: f.directory('stage'),
        idFactory: () => 'fixture-recovery-candidate-${counter++}',
        now: () => DateTime.utc(2030),
        canChooseDefault: true,);
    deletion = RecoveryDeletion(
        db: f.db, backend: backend, mutations: bound.mutations,);
  }

  GatePlayer player() {
    final value = GatePlayer()..release.complete();
    players.add(value);
    return value;
  }

  Future<void> close(WidgetTester tester) async {
    if (deletion.firstPreviewGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (deletion.originalResultGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    for (final p in players) {
      if (!p.release.isCompleted) p.release.complete();
      if (p.loadGate case final gate? when !gate.isCompleted) gate.complete();
    }
    if (owners != null) await disposeBoundWidget(tester, owners!);
    await tester.runAsync(() async {
      await backend.drain();
      await f.close();
    });
  }

  Future<GlobalKey<NavigatorState>> mountList(WidgetTester tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(f.db),
          recordingAccessProvider.overrideWithValue(owners!.access),
          recordingMutationsProvider.overrideWithValue(owners!.mutations),
          storageCatalogProvider.overrideWithValue(catalog),
          localDeletionServiceProvider.overrideWithValue(deletion),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
            navigatorKey: navigator, home: const DumpsListScreen(),),),);
    return navigator;
  }
}

void main() {
  for (final late in [false, true]) {
    testWidgets(
        'I1-I1 file-backed restart discovers original ticket through list navigation; late=$late',
        (tester) async {
      final h = RecoveryHarness();
      await tester.runAsync(h.freshOwners);
      addTearDown(() => h.close(tester));

      final a = (await tester.runAsync(() => h.f.seed('fixture-restart-a')))!;
      await tester.runAsync(() async {
        requireOk(await h.catalog.bootstrapLegacyBindings(
            filesystemLegacyDirectory: h.f.directory('A'),),);
        await h.f.seed('fixture-restart-b', folder: 'B');
        final state = await h.catalog.watchDefault().first;
        h.backend.choice = Ok(fileLocation('B', h.f.directory('B')));
        final candidate = requireOk(await h.catalog.chooseFolderCandidate())!;
        requireOk(await h.catalog
            .commitDefault(candidate, expectedRevision: state.revision),);
        await h.f.audio('B', a.key.dumpId).writeAsBytes([9, 8, 7]);
        await h.f
            .metadata('B', a.key.dumpId)
            .writeAsString('foreign same-name metadata');
      });

      final bBefore =
          (await tester.runAsync(() => h.f.db.getDump('fixture-restart-b')))!
              .toJson();
      final bMetadata = await tester
          .runAsync(() => h.f.metadata('B', 'fixture-restart-b').readAsBytes());
      final oldDb = h.f.db,
          oldOwners = h.owners!,
          oldCatalog = h.catalog,
          oldDeletion = h.deletion;
      final oldNavigator = GlobalKey<NavigatorState>();
      if (late) oldDeletion.originalResultGate = Completer<void>();
      await mount(tester, h.f, oldOwners, h.player(), oldNavigator, a,
          backend: h.backend, deletion: oldDeletion,);
      final oldState = tester.state(find.byType(DumpDetailScreen));
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await pumpBoundUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
      await tester.tap(find.byKey(const ValueKey('local-delete-confirm')));
      if (late) {
        await pumpBoundUntil(tester, () => oldDeletion.originalComputed);
        expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
        expect(oldDeletion.originalReturned, isFalse);
        oldNavigator.currentState!.pop();
        await tester.pumpAndSettle();
      } else {
        await pumpBoundUntil(tester,
            () => find.textContaining('Delete failed:').evaluate().isNotEmpty,);
      }
      final original =
          (await tester.runAsync(h.f.db.pendingLocalDeletions))!.single;
      expect(original.binding, a);
      expect(original.audio.state, ComponentState.removed);
      expect(original.metadata.state, ComponentState.failed);
      expect(h.backend.calls, hasLength(2));
      await disposeBoundWidget(tester, oldOwners);
      expect(oldState.mounted, isFalse);
      if (late) {
        oldDeletion.originalResultGate!.complete();
        await pumpBoundUntil(tester, () => oldDeletion.originalReturned);
        expect(tester.takeException(), isNull);
      }
      await tester.runAsync(() async {
        await h.backend.drain();
        await h.f.reopen();
        await h.freshOwners();
      });
      expect(identical(h.f.db, oldDb), isFalse);
      expect(identical(h.owners, oldOwners), isFalse);
      expect(identical(h.catalog, oldCatalog), isFalse);
      expect(identical(h.deletion, oldDeletion), isFalse);
      expect(
          (await tester.runAsync(() => h.catalog.watchDefault().first))!
              .location!
              .directory
              .path,
          h.f.directory('B'),);
      // Only new production owners reach the new UI. The saved ticket is assertions-only.
      await h.mountList(tester);
      final row = find.byKey(ValueKey('dump-row-${a.key.dumpId}'));
      await pumpBoundUntil(tester, () => row.evaluate().isNotEmpty);
      // Selection is action-agnostic now: the row with a saved ticket can
      // still be SELECTED (long-press live); the deletion pipeline itself
      // re-checks eligibility per target and reports the skip.
      expect(tester.widget<ListTile>(row).onLongPress, isNotNull);
      await tester.tap(row);
      await pumpBoundUntil(
          tester,
          () =>
              h.players.last.closes == 1 &&
              find
                  .byKey(ValueKey('title-editor-${a.key.dumpId}'))
                  .evaluate()
                  .isNotEmpty,);
      if (h.deletion.previews.isNotEmpty) {
        await pumpBoundUntil(tester,
            () => h.deletion.returnedPreviews == h.deletion.previews.length,);
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('Retry deletion'), findsOneWidget);
      expect(find.byKey(const ValueKey('local-delete-retry')), findsOneWidget);
      expect(find.textContaining('audio: unknown; metadata: unknown'),
          findsOneWidget,);
      expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
      expect(h.deletion.deletes, isEmpty);
      expect(h.deletion.retries, isEmpty);
      expect(h.backend.calls, hasLength(2));
      final retry = tester
          .widget<IconButton>(find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Retry deletion',),)
          .onPressed!;
      retry();
      retry();
      await tester.pumpAndSettle();
      await pumpBoundUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
      expect(
          find.text('Retry deletion of 1 local recordings?'), findsOneWidget,);
      expect(find.text('Delete 1 local recordings?'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
      await tester.pumpAndSettle();
      expect(h.backend.calls, hasLength(2));
      expect(h.deletion.retries, isEmpty);
      expect((await tester.runAsync(h.f.db.pendingLocalDeletions))!.single,
          original,);
      if (late) {
        retry();
        retry();
        await tester.pumpAndSettle();
        await pumpBoundUntil(
            tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
        await tester.tap(find.byKey(const ValueKey('local-delete-confirm')));
        await pumpBoundUntil(
            tester,
            () => find
                .textContaining('audio: removed; metadata: failed')
                .evaluate()
                .isNotEmpty,);
        expect(h.deletion.retries, hasLength(1));
        expect(h.deletion.retries.single.ticketIds, [original.id]);
        expect(h.backend.calls, hasLength(3));
        expect(
            find.byKey(const ValueKey('local-delete-retry')), findsOneWidget,);
        expect(find.textContaining('audio: unknown; metadata: unknown'),
            findsNothing,);
        expect((await tester.runAsync(h.f.db.pendingLocalDeletions))!.single.id,
            original.id,);
      }
      h.backend.metadataDeleteFails = false;
      retry();
      retry();
      await tester.pumpAndSettle();
      await pumpBoundUntil(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
      final confirm = tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('local-delete-confirm')),)
          .onPressed!;
      confirm();
      confirm();
      await pumpBoundUntil(
          tester, () => find.byType(DumpDetailScreen).evaluate().isEmpty,);
      expect(h.deletion.deletes, isEmpty);
      expect(h.deletion.retries, hasLength(late ? 2 : 1));
      for (final request in h.deletion.retries) {
        expect(request.ticketIds, [original.id]);
        expect(request.operationId, isNot(original.operationId));
        expect(() => request.ticketIds.add('wrong'), throwsUnsupportedError);
      }
      expect(h.deletion.retries.map((r) => r.operationId).toSet().length,
          h.deletion.retries.length,);
      expect(h.backend.calls, hasLength(late ? 4 : 3));
      expect(h.backend.calls.last.binding, a);
      expect(h.backend.calls.last.component, RecordingComponent.metadata);
      expect(
          (await tester.runAsync(() => h.f.db.deletionTicketById(original.id)))!
              .state,
          TicketState.completed,);
      expect(await tester.runAsync(h.f.db.pendingLocalDeletions), isEmpty);
      expect(await tester.runAsync(() => h.f.db.getDump(a.key.dumpId)), isNull);
      expect(await tester.runAsync(() => h.f.db.boundRecording(a.key.dumpId)),
          isNull,);
      expect(
          await tester.runAsync(() => h.f.db.isRetired(a.key.dumpId)), isTrue,);
      expect(
          (await tester.runAsync(() => h.f.db.getDump('fixture-restart-b')))!
              .toJson(),
          bBefore,);
      await tester.runAsync(() async {
        expect(await h.f.audio('A', a.key.dumpId).exists(), isFalse);
        expect(await h.f.metadata('A', a.key.dumpId).exists(), isFalse);
        expect(
            await h.f.audio('B', 'fixture-restart-b').readAsBytes(), [1, 2, 3],);
        expect(await h.f.metadata('B', 'fixture-restart-b').readAsBytes(),
            bMetadata,);
        expect(await h.f.audio('B', a.key.dumpId).readAsBytes(), [9, 8, 7]);
        expect(await h.f.metadata('B', a.key.dumpId).readAsString(),
            'foreign same-name metadata',);
      });
      await disposeBoundWidget(tester, h.owners!);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('I1-I1 top action revalidates while entry preview is pending',
      (tester) async {
    final h = RecoveryHarness();
    await tester.runAsync(h.freshOwners);
    addTearDown(() => h.close(tester));
    final a = (await tester.runAsync(() => h.f.seed('fixture-entry-pending')))!;
    await tester.runAsync(() async {
      final preview = requireOk(await h.deletion.preview({a.key.dumpId}));
      requireOk(await h.deletion.deleteConfirmed(
          (operationId: 'fixture-original', targets: preview.targets),),);
      await h.owners!.mutations.drain();
      await h.f.reopen();
      await h.freshOwners();
    });
    h.deletion.firstPreviewGate = Completer<void>();
    await h.mountList(tester);
    final row = find.byKey(ValueKey('dump-row-${a.key.dumpId}'));
    await pumpBoundUntil(tester, () => row.evaluate().isNotEmpty);
    await tester.tap(row);
    await pumpBoundUntil(tester, () => h.deletion.firstPreviewValue != null);
    final top = tester
        .widget<IconButton>(find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Delete'),)
        .onPressed!;
    top();
    top();
    await pumpBoundUntil(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,);
    expect(find.text('Retry deletion of 1 local recordings?'), findsOneWidget);
    expect(find.text('Delete 1 local recordings?'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await tester.pumpAndSettle();
    expect(h.backend.calls, hasLength(2));
    expect(h.deletion.deletes, isEmpty);
    expect(h.deletion.retries, isEmpty);
    h.deletion.firstPreviewGate!.complete();
    await pumpBoundUntil(tester,
        () => h.deletion.returnedPreviews == h.deletion.previews.length,);
    expect(find.byTooltip('Retry deletion'), findsOneWidget);
    expect(find.byKey(const ValueKey('local-delete-totals')), findsNothing);
    await disposeBoundWidget(tester, h.owners!);
    expect(tester.takeException(), isNull);
  });
}
