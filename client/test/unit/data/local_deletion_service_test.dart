// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

class HookBackend extends ScriptedStorageBackend {
  final calls = <RecordingComponent>[];
  IoOperation<ComponentResult> Function(
    BoundRecording,
    RecordingComponent,
    String,
  )? hook;
  IoOperation<ComponentResult> real(
    BoundRecording b,
    RecordingComponent c,
    String id,
  ) =>
      super.deleteComponent(b, c, id);
  @override
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording b,
    RecordingComponent c,
    String id,
  ) {
    calls.add(c);
    return hook == null ? real(b, c, id) : hook!(b, c, id);
  }
}

DefaultLocalDeletionService service(CatalogHarness h, [StorageBackend? b]) =>
    DefaultLocalDeletionService(
      db: h.f.db,
      backend: b ?? h.backend,
      mutations: h.mutations,
    );
Future<ConfirmedDeletion> confirmation(
  CatalogHarness h,
  String id, {
  String operation = 'fixture-batch',
}) async =>
    (
      operationId: operation,
      targets: requireOk(await service(h).preview({id})).targets
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native false-delete failure envelope retains row and metadata',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final b = await h.f.seed('fixture-native-false');
    await h.bootstrap();
    const channel = MethodChannel('fixture/deletion-false');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final components = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deleteComponentAt') {
        components.add((call.arguments as Map)['component'] as String);
        return null;
      }
      if (call.method == 'operationState') {
        return {
          'state': 'settled',
          'result': {
            'state': 'failed',
            'problem': {
              'code': 'io',
              'message': 'Provider delete returned false',
            },
          },
        };
      }
      if (call.method == 'acknowledgeOperation') {
        return null;
      }
      throw StateError('Unexpected native call ${call.method}');
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final item = requireOk(
      await service(h, backend)
          .deleteConfirmed(await confirmation(h, b.key.dumpId)),
    ).items.single;
    expect(item.state, DeleteState.failed);
    expect(item.audio.state, ComponentState.failed);
    expect(components, ['audio']);
    expect(await h.f.db.getDump(b.key.dumpId), isNotNull);
    expect(await h.f.metadata('A', b.key.dumpId).exists(), isTrue);
  });
  test(
      'cold pending batch replay observes saved progress without restarting deletion',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final b = await h.f.seed('fixture-cold-batch');
    await h.bootstrap();
    h.backend.metadataDeleteFails = true;
    final request = await confirmation(h, b.key.dumpId);
    await h.f.db.customStatement(
        "CREATE TRIGGER fixture_batch_failure BEFORE UPDATE ON local_deletion_batches WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'fixture batch checkpoint'); END",);
    expect(await service(h).deleteConfirmed(request),
        isA<Fail<BulkDeletionResult>>(),);
    final persisted =
        await h.f.db.select(h.f.db.localDeletionBatches).getSingle();
    expect(persisted.state, 'pending');
    await h.reopen();
    await h.bootstrap();
    final fresh = HookBackend();
    addTearDown(fresh.drain);
    final replay = requireOk(await service(h, fresh).deleteConfirmed(request));
    expect(replay.replayed, isTrue);
    expect(replay.items.single.ticketId, isNotNull);
    expect(replay.items.single.audio.state, ComponentState.removed);
    expect(fresh.calls, isEmpty);
    expect(await h.f.metadata('A', b.key.dumpId).exists(), isTrue);
    expect(
        await h.mutations.acquire(b.key.dumpId, UseKind.read,
            expectedIncarnation: b.key.incarnation,),
        isA<Fail<UseLease>>(),);
    await h.f.db.customStatement('DROP TRIGGER fixture_batch_failure');
    final retry = (
      operationId: 'fixture-cold-retry',
      ticketIds: [replay.items.single.ticketId!]
    );
    expect(
        requireOk(await service(h, fresh).retryConfirmed(retry))
            .items
            .single
            .state,
        DeleteState.deleted,);
    expect(fresh.calls, [RecordingComponent.metadata]);
    expect(
        await service(h, fresh).retryConfirmed(
            (operationId: retry.operationId, ticketIds: <String>[]),),
        isA<Fail<BulkDeletionResult>>(),);
    expect(fresh.calls, [RecordingComponent.metadata]);
  });

  test('retry batch persists every frozen member before first retry I/O',
      () async {
    final h = CatalogHarness();
    final entered = Completer<void>(), release = Completer<void>();
    Future<Outcome<BulkDeletionResult>>? pending;
    final backend = HookBackend();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await pending;
      await h.close();
    });
    await h.f.seed('fixture-retry-a');
    await h.f.seed('fixture-retry-b');
    await h.bootstrap();
    h.backend.metadataDeleteFails = true;
    final first = requireOk(await service(h).deleteConfirmed((
      operationId: 'fixture-retry-original',
      targets: requireOk(
              await service(h).preview({'fixture-retry-a', 'fixture-retry-b'}),)
          .targets
    ),),);
    final ids = first.items.map((i) => i.ticketId!).toList();
    backend.hook = (b, c, id) {
      if (!entered.isCompleted) entered.complete();
      final result = release.future.then((_) => backend.real(b, c, id).result);
      return GatedIo(id, result, result.then((_) {}));
    };
    pending = service(h, backend)
        .retryConfirmed((operationId: 'fixture-retry-members', ticketIds: ids));
    await entered.future;
    final batch = await h.f.db
        .customSelect(
            "SELECT results_json FROM local_deletion_batches WHERE operation_id='fixture-retry-members'",)
        .getSingle();
    expect(
        jsonDecode(batch.read<String>('results_json')) as List, hasLength(2),);
    release.complete();
    expect(
        requireOk(await pending)
            .items
            .every((i) => i.state == DeleteState.deleted),
        isTrue,);
  });

  test(
      'both proven absent finalize row binding and queue without touching decoy',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final b = await h.f.seed('fixture-absent');
    await h.bootstrap();
    await h.f.db.customStatement(
      'INSERT INTO sync_queue(dump_id,queued_at) VALUES(?,?)',
      [b.key.dumpId, 1],
    );
    await h.f.audio('B', b.key.dumpId).writeAsBytes([9]);
    await h.f.audio('A', b.key.dumpId).delete();
    await h.f.metadata('A', b.key.dumpId).delete();
    final item = requireOk(
      await service(h).deleteConfirmed(await confirmation(h, b.key.dumpId)),
    ).items.single;
    expect(item.state, DeleteState.deleted);
    expect(item.audio.state, ComponentState.absent);
    expect(item.metadata.state, ComponentState.absent);
    expect(await h.f.db.select(h.f.db.syncQueue).get(), isEmpty);
    expect(await h.f.audio('B', b.key.dumpId).readAsBytes(), [9]);
    expect(await h.f.db.boundRecording(b.key.dumpId), isNull);
    expect(await h.f.db.isRetired(b.key.dumpId), isTrue);
  });
  for (final code in [
    ProblemCode.denied,
    ProblemCode.io,
    ProblemCode.unknown,
  ]) {
    test(
        'audio $code never permits metadata destruction and independent item proceeds',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final backend = HookBackend();
      addTearDown(backend.drain);
      final bad = await h.f.seed('fixture-a-fail');
      final good = await h.f.seed('fixture-z-good');
      await h.bootstrap();
      backend.hook = (b, c, id) => b.key == bad.key
          ? ImmediateIo(
              id,
              (
                state: code == ProblemCode.unknown
                    ? ComponentState.unknown
                    : ComponentState.failed,
                problem: (code: code, message: 'PRIVATE TITLE TRANSCRIPT NOTES')
              ),
            )
          : backend.real(b, c, id);
      final targets =
          requireOk(await service(h).preview({bad.key.dumpId, good.key.dumpId}))
              .targets;
      final items = requireOk(
        await service(h, backend).deleteConfirmed(
          (operationId: 'fixture-independent', targets: targets),
        ),
      ).items;
      expect(items.first.state, DeleteState.failed);
      expect(items.last.state, DeleteState.deleted);
      expect(backend.calls, [
        RecordingComponent.audio,
        RecordingComponent.audio,
        RecordingComponent.metadata,
      ]);
      expect(await h.f.metadata('A', bad.key.dumpId).exists(), isTrue);
      expect(await h.f.db.getDump(bad.key.dumpId), isNotNull);
      final receipts = (await h.f.db.select(h.f.db.localDeletionTickets).get())
          .map((r) => r.toJson())
          .toList();
      final batches = (await h.f.db.select(h.f.db.localDeletionBatches).get())
          .map((r) => r.toJson())
          .toList();
      expect(
        jsonEncode([receipts, batches]),
        isNot(contains('PRIVATE TITLE TRANSCRIPT NOTES')),
      );
      expect(
        jsonEncode([receipts, batches]),
        isNot(contains('retained notes')),
      );
      expect(jsonEncode([receipts, batches]), isNot(contains('"title"')));
    });
  }
  test('frozen missing and wrong-incarnation confirmations never retarget',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final missing = await confirmation(h, 'fixture-later');
    await h.f.seed('fixture-later', folder: 'B');
    expect(
      requireOk(await service(h).deleteConfirmed(missing)).items.single.state,
      DeleteState.skipped,
    );
    final frozen =
        await confirmation(h, 'fixture-later', operation: 'fixture-wrong');
    await h.f.db.customStatement(
      "UPDATE recording_bindings SET incarnation='fixture-new-incarnation' WHERE dump_id='fixture-later'",
    );
    final item =
        requireOk(await service(h).deleteConfirmed(frozen)).items.single;
    expect(item.state, DeleteState.skipped);
    expect(item.problem!.code, ProblemCode.wrongIncarnation);
    expect(h.backend.componentCalls, 0);
  });
  test('playback acquired after confirmation blocks deletion until closed',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final b = await h.f.seed('fixture-playing');
    await h.bootstrap();
    final request = await confirmation(h, b.key.dumpId);
    final playback = requireOk(
      await h.mutations.acquire(
        b.key.dumpId,
        UseKind.playback,
        expectedIncarnation: b.key.incarnation,
      ),
    );
    try {
      expect(
        requireOk(await service(h).deleteConfirmed(request)).items.single.state,
        DeleteState.skipped,
      );
      expect(h.backend.componentCalls, 0);
    } finally {
      await playback.close();
    }
    expect(
      requireOk(
        await service(h).deleteConfirmed(
          await confirmation(
            h,
            b.key.dumpId,
            operation: 'fixture-after-playback',
          ),
        ),
      ).items.single.state,
      DeleteState.deleted,
    );
  });
  test(
      'DB finalization retry uses durable gone receipts without denied-root I/O',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final b = await h.f.seed('fixture-finalize');
    await h.bootstrap();
    await h.f.db.customStatement(
      "CREATE TRIGGER reject_finalize BEFORE DELETE ON dumps BEGIN SELECT RAISE(ABORT,'fixture finalization'); END",
    );
    final first = requireOk(
      await service(h).deleteConfirmed(await confirmation(h, b.key.dumpId)),
    ).items.single;
    expect(first.state, DeleteState.failed);
    expect(first.problem!.code, ProblemCode.persistence);
    expect(await h.f.audio('A', b.key.dumpId).exists(), isFalse);
    expect(await h.f.metadata('A', b.key.dumpId).exists(), isFalse);
    expect(await h.f.db.getDump(b.key.dumpId), isNotNull);
    await h.f.db.customStatement('DROP TRIGGER reject_finalize');
    await h.reopen();
    await h.bootstrap();
    final denied = HookBackend();
    addTearDown(denied.drain);
    denied.hook = (b, c, id) =>
        throw StateError('DB-only retry must not touch denied root');
    final done = requireOk(
      await service(h, denied).retryConfirmed(
        (operationId: 'fixture-finalize-retry', ticketIds: [first.ticketId!]),
      ),
    );
    expect(done.items.single.state, DeleteState.deleted);
    expect(denied.calls, isEmpty);
    expect(await h.f.db.isRetired(b.key.dumpId), isTrue);
    final completed = await h.f.db.deletionTicketById(first.ticketId!);
    expect(completed!.state, TicketState.completed);
  });
  test(
      'duplicate in-flight confirmation joins and failed result retains actual settlement',
      () async {
    final h = CatalogHarness();
    final backend = HookBackend();
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await backend.drain();
      await h.close();
    });
    final b = await h.f.seed('fixture-gated');
    await h.bootstrap();
    backend.hook = (b, c, id) {
      entered.complete();
      return GatedIo(
        id,
        Future.value(
          (
            state: ComponentState.unknown,
            problem: (code: ProblemCode.io, message: 'uncertain')
          ),
        ),
        release.future,
      );
    };
    final request = await confirmation(h, b.key.dumpId);
    var finished = false;
    final first = service(h, backend)
        .deleteConfirmed(request)
        .whenComplete(() => finished = true);
    await entered.future;
    final duplicate = service(h, backend).deleteConfirmed(request);
    expect(
      await service(h, backend).deleteConfirmed(
        (operationId: request.operationId, targets: <DeleteTarget>[]),
      ),
      isA<Fail<BulkDeletionResult>>(),
    );
    expect(finished, isFalse);
    expect(backend.calls, [RecordingComponent.audio]);
    expect(
      await h.mutations.acquire(
        b.key.dumpId,
        UseKind.read,
        expectedIncarnation: b.key.incarnation,
      ),
      isA<Fail<UseLease>>(),
    );
    release.complete();
    expect(requireOk(await first).items.single.state, DeleteState.failed);
    expect(requireOk(await duplicate).replayed, isTrue);
    expect(backend.calls, [RecordingComponent.audio]);
    expect(await h.f.metadata('A', b.key.dumpId).exists(), isTrue);
  });
  test(
      'pending batch durably records completed independent items before next I/O',
      () async {
    final h = CatalogHarness();
    final backend = HookBackend();
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await backend.drain();
      await h.close();
    });
    final a = await h.f.seed('fixture-a-first');
    final z = await h.f.seed('fixture-z-last');
    await h.bootstrap();
    backend.hook = (b, c, id) {
      if (b.key != z.key || c != RecordingComponent.audio) {
        return backend.real(b, c, id);
      }
      entered.complete();
      final done = Completer<void>();
      final result = release.future
          .then((_) => settled(backend.real(b, c, id)))
          .whenComplete(done.complete);
      return GatedIo(id, result, done.future);
    };
    final targets =
        requireOk(await service(h).preview({a.key.dumpId, z.key.dumpId}))
            .targets;
    final operation = service(h, backend)
        .deleteConfirmed((operationId: 'fixture-progress', targets: targets));
    await entered.future;
    final saved = jsonDecode(
      (await h.f.db.select(h.f.db.localDeletionBatches).getSingle())
          .resultsJson,
    ) as List;
    expect(
      saved.singleWhere((dynamic i) => i['id'] == a.key.dumpId)['state'],
      'deleted',
    );
    release.complete();
    expect(
      requireOk(await operation)
          .items
          .every((i) => i.state == DeleteState.deleted),
      isTrue,
    );
  });

  test('partial delete keeps row; explicit retry finishes original root once',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final a = await h.f.seed('fixture-delete');
    await h.f.seed('fixture-active', status: 'running');
    await h.f.audio('B', a.key.dumpId).writeAsBytes([9]);
    await h.bootstrap();
    final service = DefaultLocalDeletionService(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    final before = await h.f.db.customSelect('SELECT * FROM dumps').get();
    final preview =
        requireOk(await service.preview({a.key.dumpId, 'fixture-active'}));
    expect(h.backend.componentCalls, 0);
    expect(await h.f.db.select(h.f.db.localDeletionTickets).get(), isEmpty);
    expect(await h.f.db.select(h.f.db.localDeletionBatches).get(), isEmpty);
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps').get())
          .map((r) => r.data),
      before.map((r) => r.data),
    );
    h.backend.metadataDeleteFails = true;
    final request =
        (operationId: 'fixture-delete-batch', targets: preview.targets);
    final first = requireOk(await service.deleteConfirmed(request));
    expect(
      first.items.where((i) => i.state == DeleteState.failed),
      hasLength(1),
    );
    expect(
      first.items.where((i) => i.state == DeleteState.skipped),
      hasLength(1),
    );
    expect(await h.f.audio('A', a.key.dumpId).exists(), isFalse);
    expect(await h.f.metadata('A', a.key.dumpId).exists(), isTrue);
    expect(await h.f.db.getDump(a.key.dumpId), isNotNull);
    final calls = h.backend.componentCalls;
    expect(requireOk(await service.deleteConfirmed(request)).replayed, isTrue);
    expect(h.backend.componentCalls, calls);
    expect(
      await service.deleteConfirmed(
        (operationId: request.operationId, targets: <DeleteTarget>[]),
      ),
      isA<Fail<BulkDeletionResult>>(),
    );
    final failed =
        first.items.singleWhere((i) => i.state == DeleteState.failed);
    requireOk(
      await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 1),
    );
    await h.reopen();
    await h.bootstrap();
    expect(
      h.backend.componentCalls,
      calls,
    ); // Startup never continues destruction.
    expect(
      await h.mutations.acquire(
        a.key.dumpId,
        UseKind.read,
        expectedIncarnation: a.key.incarnation,
      ),
      isA<Fail<UseLease>>(),
    );
    final freshBackend = ScriptedStorageBackend();
    addTearDown(freshBackend.drain);
    final restored = DefaultLocalDeletionService(
      db: h.f.db,
      backend: freshBackend,
      mutations: h.mutations,
    );
    final retry = (operationId: 'fixture-retry', ticketIds: [failed.ticketId!]);
    final done = requireOk(await restored.retryConfirmed(retry));
    expect(done.items.single.state, DeleteState.deleted);
    expect(await h.f.db.getDump(a.key.dumpId), isNull);
    expect(await h.f.db.isRetired(a.key.dumpId), isTrue);
    expect(await h.f.audio('B', a.key.dumpId).readAsBytes(), [9]);
    expect(await h.f.db.getDump('fixture-active'), isNotNull);
    final after = freshBackend.componentCalls;
    expect(requireOk(await restored.retryConfirmed(retry)).replayed, isTrue);
    expect(freshBackend.componentCalls, after);
  });
}
