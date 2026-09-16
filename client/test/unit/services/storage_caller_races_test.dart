// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_coordinator.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

import '../../support/file_recorder.dart';
import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

final class DeferredIo<T> implements IoOperation<T> {
  DeferredIo(this.id, Future<T> Function() body) {
    result = _run(body);
  }

  @override
  final String id;
  @override
  late final Future<T> result;
  final Completer<void> _done = Completer<void>();
  @override
  Future<void> get settled => _done.future;

  Future<T> _run(Future<T> Function() body) async {
    try {
      return await body();
    } finally {
      _done.complete();
    }
  }
}

final class GateMetadataBackend extends ScriptedStorageBackend {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool first = true;

  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) {
    if (!first) return super.writeMetadata(binding, metadata, operationId);
    first = false;
    entered.complete();
    return DeferredIo<Outcome<void>>(operationId, () async {
      await release.future;
      return settled(super.writeMetadata(binding, metadata, operationId));
    });
  }
}

final class ReadGateBackend extends ScriptedStorageBackend {
  final entered = Completer<void>();
  final output = Completer<Outcome<Uint8List>>();
  final done = Completer<void>();
  @override
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding) {
    entered.complete();
    return GatedIo('fixture-read-result', output.future, done.future);
  }
}

final class FixtureClient extends Fake implements TranscriptionClient {
  Completer<void>? uploadRelease;
  final uploadEntered = Completer<void>();
  final List<List<int>> uploads = <List<int>>[];
  int enqueues = 0;

  @override
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async =>
      id;

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    uploads.add(List<int>.of(audioBytes));
    uploadEntered.complete();
    await uploadRelease?.future;
  }

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async {
    enqueues++;
    return TranscriptionJobSnapshot(
      id: 'fixture-job',
      requestId: requestId,
      dumpId: dumpId,
      status: 'queued',
      model: model,
    );
  }

  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {
    yield const JobEvent('running', <String, dynamic>{});
    yield const JobEvent(
      'completed',
      <String, dynamic>{'transcript': 'new synthetic words'},
    );
  }
}

Map<String, dynamic> withoutSemanticTimestamps(Map<String, dynamic> value) {
  const timestampKeys = <String>{
    'createdAt',
    'updatedAt',
    'transcriptionStartedAt',
    'transcriptionUpdatedAt',
    'transcriptionCompletedAt',
  };
  return Map<String, dynamic>.fromEntries(
    value.entries.where((entry) => !timestampKeys.contains(entry.key)),
  );
}

Future<void> eventually(Future<bool> Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(until)) fail('barrier was not reached');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('upload timeout and disposed public result retain actual transport',
      () async {
    final f = StorageFixture.create();
    final release = Completer<void>();
    final client = FixtureClient()..uploadRelease = release;
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final access =
        BoundRecordingAccess(db: f.db, backend: f.backend, mutations: m);
    final service = ServerTranscriptionService(
      client: client,
      db: f.db,
      recordingAccess: access,
      mutations: m,
      operationRequestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      service.dispose();
      await m.drain();
      await f.close();
    });
    final a = await f.seed('fixture-upload-lifetime');
    await m.restoreFences(unsettled: await f.backend.unsettledUses());
    final work = service.transcribeDump(a.key.dumpId);
    await client.uploadEntered.future;
    await work;
    service.dispose();
    expect(client.enqueues, 0);
    expect(
      await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
      ),
      isA<Fail<UseLease>>().having((failure) => failure.problem.message,
          'live admission', 'Recording is in use',),
    );
    expect(await f.audio('A', a.key.dumpId).readAsBytes(), [1, 2, 3]);
    release.complete();
    await m.drain();
    final after = await m.acquire(
      a.key.dumpId,
      UseKind.deletion,
      expectedIncarnation: a.key.incarnation,
    );
    expect(after, isA<Fail<UseLease>>());
    expect(
        (after as Fail<UseLease>).problem.message, 'Durable work is pending',);
    expect((await f.db.getDump(a.key.dumpId))!.transcriptionAttempt, 1);
    expect(client.enqueues, 0);
    expect(client.uploads, [
      [1, 2, 3],
    ]);
  });

  test('queued service sidecar blocks deletion until its FIFO turn drains',
      () async {
    final f = StorageFixture.create();
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final access =
        BoundRecordingAccess(db: f.db, backend: f.backend, mutations: m);
    final entered = Completer<void>(), release = Completer<void>();
    final client = FixtureClient();
    final service = ServerTranscriptionService(
      client: client,
      db: f.db,
      recordingAccess: access,
      mutations: m,
      sidecarWaitTimeout: const Duration(milliseconds: 30),
    );
    Future<void>? predecessor;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      service.dispose();
      await predecessor;
      await m.drain();
      await f.close();
    });
    final a = await f.seed('fixture-queued-publication');
    await m.restoreFences(unsettled: await f.backend.unsettledUses());
    predecessor =
        access.runSerializedMetadataWrite<void>(a.key, (writer) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final work = service.transcribeDump(a.key.dumpId);
    await eventually(
      () async =>
          (await f.db.getDump(a.key.dumpId))!.transcriptionStatus ==
          'completed',
    );
    await work;
    service.dispose();
    expect(
      await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
      ),
      isA<Fail<UseLease>>().having((failure) => failure.problem.message,
          'live admission', 'Recording is in use',),
    );
    release.complete();
    await predecessor;
    await m.drain();
    final after = requireOk(
      await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
      ),
    );
    await after.close();
    expect(client.enqueues, 1);
    expect((await f.db.getDump(a.key.dumpId))!.transcriptionAttempt, 1);
  });

  test('service read failure result cannot settle underlying storage IO',
      () async {
    final f = StorageFixture.create();
    final backend = ReadGateBackend();
    final held = backend;
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final client = FixtureClient();
    final service = ServerTranscriptionService(
      client: client,
      db: f.db,
      recordingAccess:
          BoundRecordingAccess(db: f.db, backend: backend, mutations: m),
      mutations: m,
    );
    addTearDown(() async {
      if (!held.output.isCompleted) {
        held.output.complete(
          const Fail((code: ProblemCode.io, message: 'fixture failure')),
        );
      }
      if (!held.done.isCompleted) held.done.complete();
      service.dispose();
      await m.drain();
      await f.close();
    });
    final a = await f.seed('fixture-read-lifetime');
    await m.restoreFences(unsettled: await backend.unsettledUses());
    final work = service.transcribeDump(a.key.dumpId);
    await backend.entered.future;
    held.output.complete(
      const Fail((code: ProblemCode.io, message: 'fixture failure')),
    );
    service.dispose();
    await work;
    expect(
      await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
      ),
      isA<Fail<UseLease>>().having((failure) => failure.problem.message,
          'live admission', 'Recording is in use',),
    );
    expect(client.uploads, isEmpty);
    expect(client.enqueues, 0);
    held.done.complete();
    await m.drain();
    final after = await m.acquire(
      a.key.dumpId,
      UseKind.deletion,
      expectedIncarnation: a.key.incarnation,
    );
    expect(after, isA<Fail<UseLease>>());
    expect(
        (after as Fail<UseLease>).problem.message, 'Durable work is pending',);
  });
  test(
      'A survives default B through publication, edit, DB reopen and local deletion',
      () async {
    final fixture = StorageFixture.create();
    final backend = GateMetadataBackend();
    final a = await fixture.seed('fixture-flow', status: 'completed');
    final originalABytes = await fixture.audio('A', a.key.dumpId).readAsBytes();
    await fixture.audio('B', a.key.dumpId).writeAsBytes(<int>[9, 9]);
    await fixture
        .metadata('B', a.key.dumpId)
        .writeAsString('unrelated', flush: true);

    final mutations = DefaultRecordingMutationCoordinator(db: fixture.db);
    final access = BoundRecordingAccess(
      db: fixture.db,
      backend: backend,
      mutations: mutations,
    );
    final client = FixtureClient();
    var ids = 0;
    final catalog = SqliteStorageCatalog(
      db: fixture.db,
      backend: backend,
      mutations: mutations,
      stagingDirectory: fixture.directory('stage'),
      idFactory: () => 'fixture-choice-${ids++}',
      now: () => DateTime.utc(2030),
      canChooseDefault: true,
    );
    final service = ServerTranscriptionService(
      client: client,
      db: fixture.db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'fixture-request',
      now: () => DateTime.utc(2030),
    );
    final recorder = FileRecorder();
    DefaultRecordingMutationCoordinator? restored;
    var serviceDisposed = false;
    var fixtureClosed = false;
    void closeService() {
      if (!serviceDisposed) {
        service.dispose();
        serviceDisposed = true;
      }
    }

    addTearDown(() async {
      if (!backend.release.isCompleted) backend.release.complete();
      closeService();
      await recorder.dispose();
      await backend.drain();
      await mutations.drain();
      await restored?.drain();
      if (!fixtureClosed) await fixture.close();
    });

    await mutations.restoreFences(unsettled: await backend.unsettledUses());
    requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: fixture.directory('A'),
      ),
    );

    final completion = service.transcribeDump(a.key.dumpId);
    await backend.entered.future;

    final before = await catalog.watchDefault().first;
    backend.choice = Ok(fileLocation('B', fixture.directory('B')));
    final candidate = requireOk(await catalog.chooseFolderCandidate())!;
    requireOk(
      await catalog.commitDefault(
        candidate,
        expectedRevision: before.revision,
      ),
    );

    final captures = DefaultRecordingCoordinator(
      db: fixture.db,
      catalog: catalog,
      backend: backend,
      mutations: mutations,
      recorder: recorder,
      now: () => DateTime.utc(2030),
    );
    final bReservation = requireOk(await captures.start(mode: 'meeting'));
    final b = requireOk(await captures.stopAndPersist())!;
    expect(b.audioPath, fixture.audio('B', b.id).path);
    expect(b.id, bReservation.key.dumpId);
    final bRow = b.toJson();
    final bMetadata = await fixture.metadata('B', b.id).readAsString();

    final deletion = DefaultLocalDeletionService(
      db: fixture.db,
      backend: backend,
      mutations: mutations,
    );
    final blocked = requireOk(await deletion.preview(<String>{a.key.dumpId}));
    final skipped = requireOk(
      await deletion.deleteConfirmed(
        (
          operationId: 'fixture-blocked',
          targets: blocked.targets,
        ),
      ),
    );
    expect(skipped.items.single.state, DeleteState.skipped);

    backend.release.complete();
    await completion;
    await mutations.drain();
    expect(client.uploads, <List<int>>[originalABytes]);
    expect(client.enqueues, 1);

    final edit = requireOk(
      await mutations.acquire(
        a.key.dumpId,
        UseKind.edit,
        expectedIncarnation: a.key.incarnation,
      ),
    );
    try {
      await fixture.db.updateDumpTitle(
        a.key.dumpId,
        storageKey: a.key,
        title: 'Edited in A',
        now: DateTime.utc(2030),
      );
      await access.runSerializedMetadataWrite<void>(a.key, (writer) async {
        final latest = (await fixture.db.getDump(a.key.dumpId))!;
        await writer.write(dumpMetadata(latest));
      });
    } finally {
      await edit.close();
    }

    final finalARow = (await fixture.db.getDump(a.key.dumpId))!;
    final actualAMetadata = jsonDecode(
      await fixture.metadata('A', a.key.dumpId).readAsString(),
    ) as Map<String, dynamic>;
    final expectedAMetadata = dumpMetadata(finalARow);
    expect(
      withoutSemanticTimestamps(actualAMetadata),
      withoutSemanticTimestamps(expectedAMetadata),
    );
    expect(finalARow.meetingNotes, 'retained notes');
    expect(
      await fixture.audio('A', a.key.dumpId).readAsBytes(),
      originalABytes,
    );
    expect(
      (await fixture.db.boundRecording(a.key.dumpId))!.key,
      a.key,
    );

    closeService();
    await backend.drain();
    await mutations.drain();
    await fixture.reopen();
    restored = DefaultRecordingMutationCoordinator(db: fixture.db);
    await restored.restoreFences(unsettled: await backend.unsettledUses());
    final reopenedBinding = (await fixture.db.boundRecording(a.key.dumpId))!;
    expect(reopenedBinding.key, a.key);
    expect(reopenedBinding.location.directory.path, fixture.directory('A'));

    final after = DefaultLocalDeletionService(
      db: fixture.db,
      backend: backend,
      mutations: restored,
    );
    final preview = requireOk(await after.preview(<String>{a.key.dumpId}));
    final deleted = requireOk(
      await after.deleteConfirmed(
        (
          operationId: 'fixture-final',
          targets: preview.targets,
        ),
      ),
    );
    expect(deleted.items.single.state, DeleteState.deleted);
    expect(await fixture.audio('A', a.key.dumpId).exists(), isFalse);
    expect(await fixture.metadata('A', a.key.dumpId).exists(), isFalse);
    expect(await fixture.audio('B', a.key.dumpId).readAsBytes(), <int>[9, 9]);
    expect(
      await fixture.metadata('B', a.key.dumpId).readAsString(),
      'unrelated',
    );
    expect((await fixture.db.getDump(b.id))!.toJson(), bRow);
    expect(await fixture.audio('B', b.id).readAsBytes(), <int>[1, 2, 3]);
    expect(await fixture.metadata('B', b.id).readAsString(), bMetadata);

    await restored.drain();
    await fixture.close();
    fixtureClosed = true;
  });
}
