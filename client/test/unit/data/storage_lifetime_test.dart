// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/services/recording_playback.dart';
import '../../support/storage_fixture.dart';

final class GatedIo<T> implements IoOperation<T> {
  GatedIo(this.id);
  @override
  final String id;
  final value = Completer<T>();
  final done = Completer<void>();
  @override
  Future<T> get result => value.future;
  @override
  Future<void> get settled => done.future;
}

class ScriptedBackend extends FilesystemStorageBackend {
  final write = GatedIo<Outcome<void>>('fixture-write');
  final entered = Completer<void>();
  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) {
    if (!entered.isCompleted) entered.complete();
    return write;
  }
}

class PendingPlayer implements RecordingPlaybackEngine {
  final loading = Completer<Duration?>();
  final disposing = Completer<void>();
  final disposeEntered = Completer<void>();
  String? source;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(String source) {
    this.source = source;
    return loading.future;
  }

  @override
  Future<void> dispose() {
    if (!disposeEntered.isCompleted) disposeEntered.complete();
    return disposing.future;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
}

void main() {
  test('drain includes a lease admitted by an outstanding catalog callback',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-drain');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final gate = Completer<void>();
    UseLease? lease;
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await lease?.close();
      await m.drain();
      await f.close();
    });
    await m.restoreFences();
    final catalog = m.catalogAdmission(() async {
      await gate.future;
      lease = requireOk(await m.acquire(a.key.dumpId, UseKind.read));
    });
    var drained = false;
    final draining = m.drain().then((_) {
      drained = true;
    });
    try {
      gate.complete();
      await catalog;
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
    } finally {
      await lease?.close();
      await draining;
    }
  });
  test('bound audio cannot redirect to B and closed reader cannot dispatch',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-read');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    AudioReadLease? reader;
    addTearDown(() async {
      await reader?.close();
      await m.drain();
      await f.close();
    });
    await f.audio('B', a.key.dumpId).writeAsBytes([9, 9, 9]);
    await m.restoreFences();
    reader = requireOk(
      await BoundRecordingAccess(db: f.db, backend: f.backend, mutations: m)
          .openAudio(a.key),
    );
    expect(await reader!.read(), [1, 2, 3]);
    expect(
      await m.acquire(a.key.dumpId, UseKind.deletion),
      isA<Fail<UseLease>>(),
    );
    await reader.close();
    await expectLater(reader.read(), throwsA(isA<StorageFault>()));
    expect(await f.audio('B', a.key.dumpId).readAsBytes(), [9, 9, 9]);
  });
  test(
      'catalog FIFO recovers after failure and capture admission is visible synchronously',
      () async {
    final f = StorageFixture.create();
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final gate = Completer<void>();
    final entered = Completer<void>();
    UseLease? capture;
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await capture?.close();
      await m.drain();
      await f.close();
    });
    await m.restoreFences();
    final admission = m.acquire(
      'fixture-capture',
      UseKind.capture,
      expectedIncarnation: 'inc-fixture',
    );
    expect(m.hasActiveCapture, isTrue);
    capture = requireOk(await admission);
    expect(capture!.binding, isNull);
    await capture.close();
    expect(m.hasActiveCapture, isFalse);
    final first = m.catalogAdmission<void>(() async {
      entered.complete();
      await gate.future;
      throw StateError('fixture');
    });
    final observed = expectLater(first, throwsStateError);
    await entered.future;
    var secondEntered = false;
    final second = m.catalogAdmission(() async {
      secondEntered = true;
      return 2;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(secondEntered, isFalse);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await observed;
      await second;
    }
    expect(secondEntered, isTrue);
  });
  test('eligibility observes live leases and queued serializer blocks deletion',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-eligibility');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final gate = Completer<void>();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await m.drain();
      await f.close();
    });
    await m.restoreFences();
    expect(
      (await m.watchEligibility().first)[a.key.dumpId],
      Eligibility.eligible,
    );
    final queue = m.serialize(a.key, () => gate.future);
    try {
      expect(
        (await m.watchEligibility().first)[a.key.dumpId],
        Eligibility.busy,
      );
      expect(
        await m.acquire(a.key.dumpId, UseKind.deletion),
        isA<Fail<UseLease>>(),
      );
    } finally {
      gate.complete();
      await queue;
    }
    expect(
      (await m.watchEligibility().first)[a.key.dumpId],
      Eligibility.eligible,
    );
  });
  test(
      'publication FIFO waits for actual I/O after failure and reads DB at head',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-fifo');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final backend = ScriptedBackend();
    final access =
        BoundRecordingAccess(db: f.db, backend: backend, mutations: m);
    final secondEntered = Completer<void>();
    final reads = <String>[];
    addTearDown(() async {
      if (!backend.write.value.isCompleted) {
        backend.write.value.complete(const Ok<void>(null));
      }
      if (!backend.write.done.isCompleted) backend.write.done.complete();
      await m.drain();
      await f.close();
    });
    await m.restoreFences();
    final first = access.runSerializedMetadataWrite(a.key, (writer) async {
      await writer.write({'id': a.key.dumpId});
    });
    final failureObserved = expectLater(first, throwsStateError);
    await backend.entered.future;
    final second = access.runSerializedMetadataWrite(a.key, (_) async {
      reads.add((await f.db.getDump(a.key.dumpId))!.title);
      secondEntered.complete();
      return 2;
    });
    backend.write.value.completeError(StateError('Result observer failed'));
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondEntered.isCompleted, isFalse);
      final deletion = await m.acquire(a.key.dumpId, UseKind.deletion);
      if (deletion case Ok<UseLease>(:final value)) await value.close();
      expect(deletion, isA<Fail<UseLease>>());
      await f.db.updateDumpTitle(
        a.key.dumpId,
        title: 'after-first',
        now: DateTime.utc(2031),
      );
      backend.write.done.complete();
      await failureObserved;
      expect(await second, 2);
      expect(reads, ['after-first']);
    } finally {
      if (!backend.write.done.isCompleted) backend.write.done.complete();
      await failureObserved;
      await second;
    }
  });
  test('playback pending load and dispose both retain protection', () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-playback');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final raw = PendingPlayer();
    final access =
        BoundRecordingAccess(db: f.db, backend: f.backend, mutations: m);
    PlaybackLease? playback;
    addTearDown(() async {
      if (!raw.loading.isCompleted) raw.loading.complete(Duration.zero);
      if (!raw.disposing.isCompleted) raw.disposing.complete();
      await playback?.close();
      await m.drain();
      await f.close();
    });
    await m.restoreFences();
    playback = requireOk(await access.openPlayback(a.key, raw));
    expect(playback!.source, a.audio);
    final load = playback.engine.load(a.audio.value);
    final closing = playback.close();
    await raw.disposeEntered.future;
    final busy = await m.acquire(a.key.dumpId, UseKind.deletion);
    if (busy case Ok<UseLease>(:final value)) await value.close();
    expect(busy, isA<Fail<UseLease>>());
    raw.disposing.complete();
    await Future<void>.delayed(Duration.zero);
    final stillBusy = await m.acquire(a.key.dumpId, UseKind.deletion);
    if (stillBusy case Ok<UseLease>(:final value)) await value.close();
    expect(stillBusy, isA<Fail<UseLease>>());
    raw.loading.complete(Duration.zero);
    await load;
    await closing;
    final deletion = requireOk(await m.acquire(a.key.dumpId, UseKind.deletion));
    await deletion.close();
  });
  test('same-time admission reserves before DB await in both call orders',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-race');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    addTearDown(() async {
      await m.drain();
      await f.close();
    });
    expect(await m.acquire(a.key.dumpId, UseKind.read), isA<Fail<UseLease>>());
    await m.restoreFences();
    for (final kinds in [
      [UseKind.read, UseKind.deletion],
      [UseKind.deletion, UseKind.read],
      [UseKind.deletion, UseKind.deletion],
    ]) {
      final results = await Future.wait(
        kinds.map(
          (kind) => m.acquire(
            a.key.dumpId,
            kind,
            expectedIncarnation: a.key.incarnation,
          ),
        ),
      );
      for (final result in results.whereType<Ok<UseLease>>()) {
        await result.value.close();
      }
      expect(results.first, isA<Ok<UseLease>>());
      expect(results.last, isA<Fail<UseLease>>());
    }
    final shared = await Future.wait([
      m.acquire(a.key.dumpId, UseKind.read),
      m.acquire(a.key.dumpId, UseKind.edit),
    ]);
    for (final result in shared) {
      await requireOk(result).close();
    }
    expect(
      await m.acquire(
        a.key.dumpId,
        UseKind.read,
        expectedIncarnation: 'wrong',
      ),
      isA<Fail<UseLease>>(),
    );
  });
  test(
      'restored worker and closing lease cannot release early or start children',
      () async {
    final f = StorageFixture.create();
    final a = await f.seed('fixture-restored');
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    final done = Completer<void>();
    addTearDown(() async {
      if (!done.isCompleted) done.complete();
      await m.drain();
      await f.close();
    });
    await m.restoreFences(
      unsettled: [
        (key: a.key, kind: UseKind.publication, settled: done.future),
      ],
    );
    expect(
      await m.acquire(a.key.dumpId, UseKind.deletion),
      isA<Fail<UseLease>>(),
    );
    done.complete();
    await m.drain();
    final lease = requireOk(await m.acquire(a.key.dumpId, UseKind.read));
    await expectLater(
      m.runIo<int>(lease, () => throw StateError('Not dispatched')),
      throwsStateError,
    );
    await lease.close();
    var dispatched = false;
    await expectLater(
      m.runIo<int>(lease, () {
        dispatched = true;
        return GatedIo<int>('never');
      }),
      throwsA(isA<StorageFault>()),
    );
    expect(dispatched, isFalse);
  });
  for (final failResult in [false, true]) {
    test(
        'outer timeout and close retain actual I/O (result failure=$failResult)',
        () async {
      final f = StorageFixture.create();
      final a = await f.seed('fixture-lifetime');
      final m = DefaultRecordingMutationCoordinator(db: f.db);
      final io = GatedIo<int>('fixture-io');
      UseLease? lease;
      addTearDown(() async {
        if (!io.value.isCompleted) io.value.complete(7);
        if (!io.done.isCompleted) io.done.complete();
        await lease?.close();
        await m.drain();
        await f.close();
      });
      await m.restoreFences();
      lease = requireOk(
        await m.acquire(
          a.key.dumpId,
          UseKind.publication,
          expectedIncarnation: a.key.incarnation,
        ),
      );
      final retained = m.runIo(lease!, () => io);
      await expectLater(
        retained.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      final closing = lease.close();
      var closed = false;
      unawaited(
        closing.then((_) {
          closed = true;
        }),
      );
      if (failResult) {
        final observed = expectLater(retained, throwsStateError);
        io.value.completeError(StateError('lost result'));
        await observed;
      } else {
        io.value.complete(7);
        expect(await retained, 7);
      }
      final busy = await m.acquire(
        a.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: a.key.incarnation,
      );
      if (busy case Ok<UseLease>(:final value)) await value.close();
      expect(busy, isA<Fail<UseLease>>());
      expect((busy as Fail<UseLease>).problem.code, ProblemCode.busy);
      expect(closed, isFalse);
      io.done.complete();
      await closing;
      final deletion = requireOk(
        await m.acquire(
          a.key.dumpId,
          UseKind.deletion,
          expectedIncarnation: a.key.incarnation,
        ),
      );
      await deletion.close();
    });
  }
}
