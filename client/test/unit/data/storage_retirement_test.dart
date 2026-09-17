// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';

DeleteTarget target(BoundRecording b) => (
      id: b.key.dumpId,
      binding: b,
      title: 'Synthetic',
      eligibility: Eligibility.eligible,
      retryTicketId: null
    );
const removed = (state: ComponentState.removed, problem: null);
const absent = (state: ComponentState.absent, problem: null);
void main() {
  test('public title mutation cannot cross a claimed deletion fence', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-title-fenced', status: 'completed');
    final original = (await f.db.getDump(a.key.dumpId))!;
    requireOk(await f.db.claimLocalDeletion('fixture-title-claim', target(a)));
    await expectLater(
      f.db.updateDumpTitle(
        a.key.dumpId,
        storageKey: a.key,
        title: 'forbidden late title',
        now: DateTime.utc(2031),
      ),
      throwsA(isA<StorageFault>()),
    );
    expect(await f.db.getDump(a.key.dumpId), original);
  });
  test('pending claim replay rereads durable status and exact current binding',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-replay');
    final t =
        requireOk(await f.db.claimLocalDeletion('fixture-batch', target(a)));
    await (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
        .write(const DumpsCompanion(syncStatus: Value('syncing')));
    expect(
      await f.db.claimLocalDeletion('fixture-batch', target(a)),
      isA<Fail<DeletionTicket>>(),
    );
    await (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
        .write(const DumpsCompanion(syncStatus: Value('local_only')));
    await (f.db.update(f.db.recordingBindings)
          ..where((b) => b.dumpId.equals(a.key.dumpId)))
        .write(const RecordingBindingsCompanion(incarnation: Value('foreign')));
    expect(
      await f.db.claimLocalDeletion('fixture-batch', target(a)),
      isA<Fail<DeletionTicket>>(),
    );
    expect((await f.db.pendingLocalDeletions()).single.id, t.id);
  });
  test(
      'finalization transaction rolls back binding and queue if row delete fails',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-rollback', status: 'completed');
    await f.db.into(f.db.syncQueue).insert(
          SyncQueueCompanion.insert(
            dumpId: a.key.dumpId,
            queuedAt: DateTime.utc(2030),
          ),
        );
    final t =
        requireOk(await f.db.claimLocalDeletion('fixture-batch', target(a)));
    await f.db.recordDeletionComponent(t.id, RecordingComponent.audio, removed);
    await f.db
        .recordDeletionComponent(t.id, RecordingComponent.metadata, absent);
    await f.db.customStatement(
      "CREATE TRIGGER fixture_abort BEFORE DELETE ON dumps BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
    );
    await expectLater(
      f.db.finishLocalDeletion(t.id),
      throwsA(isA<Exception>()),
    );
    expect(await f.db.boundRecording(a.key.dumpId), a);
    expect(await f.db.select(f.db.syncQueue).get(), hasLength(1));
    expect(await f.db.searchDumps('retained'), hasLength(1));
    expect(await f.db.isRetired(a.key.dumpId), isFalse);
    await f.db.customStatement('DROP TRIGGER fixture_abort');
    await f.db.finishLocalDeletion(t.id);
    expect(await f.db.isRetired(a.key.dumpId), isTrue);
  });
  test('durable exact ticket finalizes atomically and survives real reopen',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-retirement', status: 'completed');
    final row = (await f.db.getDump(a.key.dumpId))!;
    await f.db.into(f.db.syncQueue).insert(
          SyncQueueCompanion.insert(
            dumpId: a.key.dumpId,
            queuedAt: DateTime.utc(2030),
          ),
        );
    expect(await f.db.boundRecording(a.key.dumpId), a);
    expect(
      await f.db.mutationAllowed((dumpId: a.key.dumpId, incarnation: 'wrong')),
      isFalse,
    );
    final t =
        requireOk(await f.db.claimLocalDeletion('fixture-batch', target(a)));
    expect(
      requireOk(await f.db.claimLocalDeletion('fixture-batch', target(a))),
      t,
    );
    expect(await f.db.mutationAllowed(a.key), isFalse);
    await expectLater(f.db.bindRecording(a), throwsA(isA<StorageFault>()));
    await expectLater(
      f.db.finishLocalDeletion(t.id),
      throwsA(isA<StorageFault>()),
    );
    await f.db.recordDeletionComponent(t.id, RecordingComponent.audio, removed);
    await f.db.recordDeletionComponent(
      t.id,
      RecordingComponent.metadata,
      (
        state: ComponentState.failed,
        problem: (code: ProblemCode.denied, message: 'Fixture denied')
      ),
    );
    await f.reopen();
    final saved = (await f.db.pendingLocalDeletions()).single;
    expect(saved.binding, a);
    expect(saved.audio, removed);
    expect(saved.metadata.problem?.code, ProblemCode.denied);
    expect(saved.state, TicketState.failed);
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    await m.restoreFences();
    for (final kind in [
      UseKind.acceptance,
      UseKind.publication,
      UseKind.read,
    ]) {
      expect(
        await m.acquire(
          a.key.dumpId,
          kind,
          expectedIncarnation: a.key.incarnation,
        ),
        isA<Fail<UseLease>>(),
      );
    }
    expect(
      await m.acquire(a.key.dumpId, UseKind.deletion, retryTicketId: 'wrong'),
      isA<Fail<UseLease>>(),
    );
    final retry = requireOk(
      await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
        retryTicketId: t.id,
      ),
    );
    await retry.close();
    await m.drain();
    expect(await f.audio('A', a.key.dumpId).readAsBytes(), [1, 2, 3]);
    expect(await f.db.getDump(a.key.dumpId), row);
    await f.db
        .recordDeletionComponent(t.id, RecordingComponent.metadata, absent);
    await f.db.finishLocalDeletion(t.id);
    await f.db.finishLocalDeletion(t.id);
    await f.reopen();
    expect(await f.db.isRetired(a.key.dumpId), isTrue);
    expect(await f.db.getDump(a.key.dumpId), isNull);
    expect(await f.db.boundRecording(a.key.dumpId), isNull);
    expect(await f.db.select(f.db.syncQueue).get(), isEmpty);
    expect(await f.db.searchDumps('retained'), isEmpty);
    expect(await f.db.pendingLocalDeletions(), isEmpty);
    await expectLater(f.db.bindRecording(a), throwsA(isA<StorageFault>()));
    await expectLater(
      f.db.updateDumpTitle(row.id,
          storageKey: a.key, title: row.title, now: row.updatedAt,),
      throwsA(isA<StorageFault>()),
    );
    final receipt = await f.db
        .customSelect('SELECT * FROM local_deletion_tickets')
        .getSingle();
    expect(receipt.data['state'], 'completed');
    expect(receipt.data.toString(), isNot(contains('retained words')));
    expect(receipt.data.toString(), isNot(contains('retained notes')));
    expect(receipt.data.toString(), isNot(contains('Synthetic')));
    // These are modeled receipts, not a claim that this primitive deleted files.
    expect(await f.audio('A', a.key.dumpId).exists(), isTrue);
  });
  test(
      'claim rereads statuses, sidecar marker and exact binding under transaction',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-claim');
    final original = (await f.db.getDump(a.key.dumpId))!;
    for (final status in ['uploading', 'queued', 'running']) {
      // Explicit fixture setup, not a general production mutation API.
      await f.db.into(f.db.dumps).insertOnConflictUpdate(
            original.copyWith(transcriptionStatus: status),
          );
      expect(
        await f.db.claimLocalDeletion('fixture-$status', target(a)),
        isA<Fail<DeletionTicket>>(),
      );
    }
    await f.db.into(f.db.dumps).insertOnConflictUpdate(
          original.copyWith(syncStatus: 'syncing'),
        );
    expect(
      await f.db.claimLocalDeletion('fixture-sync', target(a)),
      isA<Fail<DeletionTicket>>(),
    );
    await f.db.into(f.db.dumps).insertOnConflictUpdate(
          original.copyWith(
            transcriptionStatus: 'failed',
            transcriptionError: const Value('sidecar_sync_pending: fixture'),
          ),
        );
    expect(
      await f.db.claimLocalDeletion('fixture-marker', target(a)),
      isA<Fail<DeletionTicket>>(),
    );
    await (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
        .write(const DumpsCompanion(transcriptionError: Value(null)));
    await f.db.into(f.db.dumps).insertOnConflictUpdate(original);
    final wrong = (
      key: (dumpId: a.key.dumpId, incarnation: 'wrong'),
      location: a.location,
      audio: a.audio,
      metadataName: a.metadataName
    );
    expect(
      await f.db.claimLocalDeletion('fixture-wrong', target(wrong)),
      isA<Fail<DeletionTicket>>(),
    );
    await expectLater(f.db.bindRecording(wrong), throwsA(isA<StorageFault>()));
    expect(await f.db.select(f.db.localDeletionTickets).get(), isEmpty);
    expect(await f.db.getDump(a.key.dumpId), original);
    final results = await Future.wait([
      f.db.claimLocalDeletion('fixture-one', target(a)),
      f.db.claimLocalDeletion('fixture-two', target(a)),
    ]);
    expect(results.whereType<Ok<DeletionTicket>>(), hasLength(1));
    expect(results.whereType<Fail<DeletionTicket>>(), hasLength(1));
    expect(await f.db.select(f.db.localDeletionTickets).get(), hasLength(1));
  });
  test('binding insert validates immutable source and known directory',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-bind');
    await f.db.bindRecording(a); // exact replay
    await (f.db.delete(f.db.recordingBindings)
          ..where((b) => b.dumpId.equals(a.key.dumpId)))
        .go();
    await f.db.bindRecording(a);
    expect(await f.db.boundRecording(a.key.dumpId), a);
    final other = (
      key: a.key,
      location: fileLocation('B', f.directory('B')),
      audio: (kind: 'file', value: f.audio('B', a.key.dumpId).path),
      metadataName: a.metadataName
    );
    await expectLater(f.db.bindRecording(other), throwsA(isA<StorageFault>()));
    expect(await f.db.boundRecording(a.key.dumpId), a);
  });
  test('guarded mutation cannot reinsert an already retired ID', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-retired-insert');
    final row = (await f.db.getDump(a.key.dumpId))!;
    // Preserved v5 receipt represents a prior completed deletion at startup.
    await f.db.customStatement(
        'INSERT INTO local_deletion_tickets(dump_id,incarnation,ticket_id,operation_id,binding_json,audio_state,metadata_state,state) VALUES(?,?,?,?,?,?,?,?)',
        [
          a.key.dumpId,
          a.key.incarnation,
          'fixture-ticket',
          'fixture-batch',
          StorageCodec.encodeBinding(a),
          'removed',
          'absent',
          'completed',
        ]);
    await f.db.delete(f.db.recordingBindings).go();
    await f.db.delete(f.db.dumps).go();
    await expectLater(
      f.db.updateDumpTitle(row.id,
          storageKey: a.key, title: row.title, now: row.updatedAt,),
      throwsA(isA<StorageFault>()),
    );
    expect(await f.db.getDump(a.key.dumpId), isNull);
  });
}
