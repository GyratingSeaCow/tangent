// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/recording_importer.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/services/recording_coordinator.dart';
import '../../support/file_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../../support/storage_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/data/storage/filesystem_capture_io.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import '../../support/scripted_storage_backend.dart';

class AckDb extends LocalDb {
  AckDb(super.executor) : super.forTesting();
  @override
  Future<T> commitOwnedCapture<T>(Future<T> Function() action) async {
    await super.commitOwnedCapture(action);
    throw SqliteException(10, 'synthetic committed but acknowledgment lost');
  }
}

class CommitHookDb extends LocalDb {
  CommitHookDb(super.executor) : super.forTesting();
  Future<void> Function()? afterCommit;
  @override
  Future<T> commitOwnedCapture<T>(Future<T> Function() action) async {
    final result = await super.commitOwnedCapture(action);
    final hook = afterCommit;
    afterCommit = null;
    await hook?.call();
    return result;
  }
}

class ControlledRecorder implements RecordingService {
  ControlledRecorder(this.failure);
  final String failure;
  final inner = FileRecorder();
  @override
  bool get isRecording => inner.isRecording;
  @override
  String? get currentPath => inner.currentPath;
  @override
  Future<bool> requestPermission() => inner.requestPermission();
  @override
  Stream<double> amplitudeStream(Duration interval) =>
      inner.amplitudeStream(interval);
  @override
  Future<String> start({required String stagingPath}) async {
    if (failure == 'start-error') throw StateError('synthetic start error');
    final path = await inner.start(stagingPath: stagingPath);
    return failure == 'start-path' ? '$path.foreign' : path;
  }

  @override
  Future<RecordingResult?> stop() async {
    final result = (await inner.stop())!;
    if (failure == 'null') return null;
    if (failure == 'error') throw StateError('synthetic stop error');
    return RecordingResult(
      path: failure == 'path' ? '${result.path}.foreign' : result.path,
      durationSeconds: 3,
      sizeBytes: failure == 'size' ? 0 : result.sizeBytes,
    );
  }

  @override
  Future<void> dispose() => inner.dispose();
}

IoOperation<T> fixtureIo<T>(Future<T> Function() action) {
  final done = Completer<void>();
  final future = () async {
    try {
      return await action();
    } finally {
      done.complete();
    }
  }();
  return GatedIo('fixture-io', future, done.future);
}

DefaultRecordingCoordinator capture(
  CatalogHarness h,
  RecordingService recorder,
) =>
    DefaultRecordingCoordinator(
      db: h.f.db,
      catalog: h.catalog,
      backend: h.backend,
      mutations: h.mutations,
      recorder: recorder,
      now: () => DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
    );

CaptureObjectIdentity fileIdentity(String path) {
  final handle = openCaptureHandle(path);
  try {
    return handle.identity;
  } finally {
    handle.close();
  }
}

class ReadOnlyCaptureBackend extends FilesystemStorageBackend {
  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadata,
    String digest,
    String operationId, {
    required bool observeOnly,
  }) =>
      throw StateError('Recovery must not prepare');
  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      throw StateError('Complete recovery must not initialize');
}

void main() {
  test(
      'T5-I2 receipt-only UPDATE failure recovers exact claims read-only after reopen',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    addTearDown(() async {
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    await h.f.db.customStatement('''
      CREATE TRIGGER reject_receipt BEFORE UPDATE OF publication_json ON capture_reservations
      WHEN json_type(OLD.publication_json, '\$.published') = 'null'
       AND json_type(NEW.publication_json, '\$.published') = 'object'
      BEGIN SELECT RAISE(ABORT, 'fixture receipt checkpoint only'); END
    ''');
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    final audio = h.f.audio('A', r.key.dumpId);
    final metadata = h.f.metadata('A', r.key.dumpId);
    expect(await audio.readAsBytes(), [1, 2, 3]);
    final beforeAudio = fileIdentity(audio.path);
    final beforeMetadata = fileIdentity(metadata.path);
    final metadataBytes = await metadata.readAsBytes();
    final journal = jsonDecode(
      (await h.f.db.select(h.f.db.captureReservations).getSingle())
          .publicationJson!,
    ) as Map;
    expect(journal['published'], isNull);
    expect(journal['version'], 2);
    final prepared = CapturePublicationCodec.decodePreparation(
      jsonEncode((journal['handoff'] as Map)['preparation']),
    );
    expect(prepared.audio!.identity, beforeAudio);
    expect(prepared.metadata!.identity, beforeMetadata);
    expect(await h.f.db.getDump(r.key.dumpId), isNull);
    expect(await h.f.db.select(h.f.db.recordingBindings).get(), isEmpty);
    await h.f.db.customStatement('DROP TRIGGER reject_receipt');
    await h.reopen();
    final backend = ReadOnlyCaptureBackend();
    final catalog = SqliteStorageCatalog(
      db: h.f.db,
      backend: backend,
      mutations: h.mutations,
      stagingDirectory: h.f.directory('stage'),
      canChooseDefault: true,
      idFactory: () => 'fixture-reopen-${h.counter++}',
      now: () => DateTime.utc(2030),
    );
    requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
    );
    final recovered = await RecordingPersistence(
      db: h.f.db,
      backend: backend,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    expect(recovered.problems, isEmpty);
    expect(recovered.recoveredIds, [r.key.dumpId]);
    expect(recovered.retainedReservationIds, isEmpty);
    expect(await h.f.db.select(h.f.db.dumps).get(), hasLength(1));
    expect(await h.f.db.select(h.f.db.recordingBindings).get(), hasLength(1));
    expect((await h.f.db.boundRecording(r.key.dumpId))!.location, r.location);
    expect(await audio.readAsBytes(), [1, 2, 3]);
    expect(await metadata.readAsBytes(), metadataBytes);
    expect(fileIdentity(audio.path), beforeAudio);
    expect(fileIdentity(metadata.path), beforeMetadata);
    expect(await File(r.stagingPath).exists(), isFalse);
  });
  test('T5-I1 failed recovery releases admission only after settlement',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    final entered = Completer<void>();
    final result = Completer<Outcome<PublishedCapture>>();
    final finished = Completer<void>();
    Future<Outcome<OwnedCaptureRecoveryResult>>? recovery;
    addTearDown(() async {
      if (!result.isCompleted) {
        result.complete(const Fail((code: ProblemCode.io, message: 'fixture')));
      }
      if (!finished.isCompleted) finished.complete();
      await recovery;
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    h.backend.publication = (_, __) => ImmediateIo(
          'fixture-initial-failure',
          const Fail((code: ProblemCode.denied, message: 'fixture denied')),
        );
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    final before = await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(before.state, 'failed');
    expect(jsonDecode(before.publicationJson!)['published'], isNull);
    final bytes = await File(r.stagingPath).readAsBytes();
    h.backend.publication = (_, __) {
      entered.complete();
      return GatedIo('fixture-recovery', result.future, finished.future);
    };
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    var returned = false;
    recovery = importer.recoverOwnedCaptures().then((value) {
      returned = true;
      return value;
    });
    await entered.future;
    result.complete(
      const Fail((code: ProblemCode.denied, message: 'fixture denied')),
    );
    final candidate = await h.choose('B');
    final blockedDefault =
        await h.catalog.commitDefault(candidate, expectedRevision: 1);
    expect(
      (blockedDefault as Fail<DefaultFolderState>).problem.code,
      ProblemCode.busy,
    );
    final blockedCapture = await h.catalog.reserveCapture(mode: 'meeting');
    expect(
      (blockedCapture as Fail<CaptureReservation>).problem.code,
      ProblemCode.busy,
    );
    expect(returned, isFalse);
    expect(h.mutations.hasActiveCapture, isTrue);
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).state,
      'publishing',
    );
    finished.complete();
    final failed = requireOk(await recovery);
    expect(failed.problems.single.code, ProblemCode.denied);
    expect(failed.recoveredIds, isEmpty);
    expect(failed.retainedReservationIds, [r.id]);
    final retained =
        await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(retained.state, 'failed');
    expect(retained.publicationJson, before.publicationJson);
    expect(retained.processEpoch, before.processEpoch);
    expect(retained.startedAt, before.startedAt);
    expect(await File(r.stagingPath).readAsBytes(), bytes);
    expect(h.mutations.hasActiveCapture, isFalse);
    requireOk(
      await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 1),
    );
    final next = requireOk(await c.start(mode: 'meeting'));
    expect(next.location.directory.path, h.f.directory('B'));
    h.backend.publication = null;
    requireOk(await c.stopAndPersist());
    final retried = requireOk(await importer.recoverOwnedCaptures());
    expect(retried.problems, isEmpty);
    expect(retried.recoveredIds, [r.key.dumpId]);
    expect(retried.retainedReservationIds, isEmpty);
    expect((await h.f.db.boundRecording(r.key.dumpId))!.location, r.location);
    expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), bytes);
    expect(await h.f.audio('B', r.key.dumpId).exists(), isFalse);
    expect(await File(r.stagingPath).exists(), isFalse);
  });
  test('T5-I1 recovery DB commit failure retains receipt and permits retry',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    final entered = Completer<void>();
    final result = Completer<Outcome<List<ImportedEntry>>>();
    final finished = Completer<void>();
    Future<Outcome<OwnedCaptureRecoveryResult>>? recovery;
    addTearDown(() async {
      if (!result.isCompleted) result.complete(const Ok([]));
      if (!finished.isCompleted) finished.complete();
      await recovery;
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    h.backend.publication = (_, __) => ImmediateIo(
          'fixture-initial-failure',
          const Fail((code: ProblemCode.io, message: 'fixture unavailable')),
        );
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    final original =
        await h.f.db.select(h.f.db.captureReservations).getSingle();
    h.backend.publication = null;
    h.backend.listing = (_) {
      entered.complete();
      return GatedIo(
        'fixture-verify-publication',
        result.future,
        finished.future,
      );
    };
    await h.f.db.customStatement(
      "CREATE TRIGGER fixture_fail_commit BEFORE INSERT ON dumps BEGIN SELECT RAISE(ABORT, 'fixture DB commit failure'); END",
    );
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    var returned = false;
    recovery = importer.recoverOwnedCaptures().then((value) {
      returned = true;
      return value;
    });
    await entered.future;
    // Production filesystem publication and receipt journaling have succeeded.
    final published =
        await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(published.state, 'publishing');
    expect(jsonDecode(published.publicationJson!)['published'], isNotNull);
    final finalAudio = await h.f.audio('A', r.key.dumpId).readAsBytes();
    final finalMetadata = await h.f.metadata('A', r.key.dumpId).readAsBytes();
    result.complete(await settled(h.f.backend.listRecordingsAt(r.location)));
    final blockedDefault =
        await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 1);
    expect(
      (blockedDefault as Fail<DefaultFolderState>).problem.code,
      ProblemCode.busy,
    );
    expect(
      (await h.catalog.reserveCapture(mode: 'meeting')
              as Fail<CaptureReservation>)
          .problem
          .code,
      ProblemCode.busy,
    );
    expect(returned, isFalse);
    expect(h.mutations.hasActiveCapture, isTrue);
    expect(await h.f.db.getDump(r.key.dumpId), isNull);
    finished.complete();
    final failed = requireOk(await recovery);
    expect(failed.problems.single.code, ProblemCode.persistence);
    expect(failed.retainedReservationIds, [r.id]);
    final retained =
        await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(retained.state, 'failed');
    expect(retained.publicationJson, published.publicationJson);
    expect(retained.startedAt, original.startedAt);
    expect(retained.processEpoch, original.processEpoch);
    expect(await File(r.stagingPath).readAsBytes(), finalAudio);
    expect(await h.f.db.getDump(r.key.dumpId), isNull);
    expect(await h.f.db.boundRecording(r.key.dumpId), isNull);
    expect(h.mutations.hasActiveCapture, isFalse);
    await h.f.db.customStatement('DROP TRIGGER fixture_fail_commit');
    h.backend.listing = null;
    requireOk(
      await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 1),
    );
    final next = requireOk(await c.start(mode: 'meeting'));
    expect(next.location.directory.path, h.f.directory('B'));
    requireOk(await c.stopAndPersist());
    final calls = h.backend.publishedReservations.length;
    final retried = requireOk(await importer.recoverOwnedCaptures());
    expect(retried.problems, isEmpty);
    expect(retried.recoveredIds, [r.key.dumpId]);
    expect(retried.retainedReservationIds, isEmpty);
    expect(h.backend.publishedReservations.length, calls);
    expect((await h.f.db.boundRecording(r.key.dumpId))!.location, r.location);
    expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), finalAudio);
    expect(await h.f.metadata('A', r.key.dumpId).readAsBytes(), finalMetadata);
    expect(await File(r.stagingPath).exists(), isFalse);
  });

  for (final changed in ['epoch', 'reserved', 'recording', 'failure-write']) {
    test('T5-I1 recovery contains failure without changing $changed owner',
        () async {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      final entered = Completer<void>();
      final result = Completer<Outcome<PublishedCapture>>();
      final finished = Completer<void>();
      Future<Outcome<OwnedCaptureRecoveryResult>>? recovery;
      addTearDown(() async {
        if (!result.isCompleted) {
          result
              .complete(const Fail((code: ProblemCode.io, message: 'fixture')));
        }
        if (!finished.isCompleted) finished.complete();
        await recovery;
        await recorder.dispose();
        await h.close();
      });
      await h.bootstrap();
      final c = capture(h, recorder);
      final r = requireOk(await c.start(mode: 'meeting'));
      h.backend.publication = (_, __) => ImmediateIo(
            'fixture-first-failure',
            const Fail((code: ProblemCode.io, message: 'fixture')),
          );
      expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
      h.backend.publication = (_, __) {
        entered.complete();
        return GatedIo(
          'fixture-recovery-owner',
          result.future,
          finished.future,
        );
      };
      final importer = BoundRecordingImporter(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      );
      recovery = importer.recoverOwnedCaptures();
      await entered.future;
      if (changed == 'epoch') {
        await h.f.db.customStatement(
          'UPDATE capture_reservations SET process_epoch=? WHERE reservation_id=?',
          ['fixture-replacement', r.id],
        );
      } else if (changed == 'failure-write') {
        await h.f.db.customStatement(
          "CREATE TRIGGER fixture_fail_failure BEFORE UPDATE OF state ON capture_reservations WHEN NEW.state='failed' BEGIN SELECT RAISE(ABORT, 'fixture secondary failure'); END",
        );
      } else {
        await h.f.db.customStatement(
          'UPDATE capture_reservations SET state=? WHERE reservation_id=?',
          [changed, r.id],
        );
      }
      final before = (await h.f.db
              .customSelect('SELECT * FROM capture_reservations')
              .getSingle())
          .data;
      result.complete(
        const Fail(
          (code: ProblemCode.denied, message: 'fixture primary denial'),
        ),
      );
      finished.complete();
      final failed = requireOk(await recovery);
      expect(
        failed.problems.single,
        (code: ProblemCode.denied, message: 'fixture primary denial'),
      );
      expect(failed.retainedReservationIds, [r.id]);
      expect(
        (await h.f.db
                .customSelect('SELECT * FROM capture_reservations')
                .getSingle())
            .data,
        before,
      );
      expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
      expect(h.mutations.hasActiveCapture, isFalse);
      if (changed == 'failure-write') {
        await h.f.db.customStatement('DROP TRIGGER fixture_fail_failure');
        h.backend.publication = null;
        expect(
          requireOk(await importer.recoverOwnedCaptures()).recoveredIds,
          [r.key.dumpId],
        );
      }
    });
  }

  test('owned recovery waits for catalog admission before provider work',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    final entered = Completer<void>();
    final release = Completer<void>();
    final published = Completer<void>();
    Future<void>? admission;
    Future<Outcome<OwnedCaptureRecoveryResult>>? recovery;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await admission;
      await recovery;
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    requireOk(await c.start(mode: 'meeting'));
    h.backend.publication = (_, __) => ImmediateIo(
          'fixture-first-failure',
          const Fail((code: ProblemCode.io, message: 'synthetic')),
        );
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    h.backend.publication = (r, metadata) {
      published.complete();
      return h.f.backend.publishPreparedCapture(r, metadata);
    };
    admission = h.mutations.catalogAdmission(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    recovery = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    final started = await Future.any([
      published.future.then((_) => true),
      Future<bool>.delayed(const Duration(milliseconds: 80), () => false),
    ]);
    expect(started, isFalse);
    release.complete();
    expect(requireOk(await recovery).recoveredIds, hasLength(1));
  });

  test('final deletion cannot remove row with a retained staging journal',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final binding =
        await f.seed('fixture-finalize-journal', status: 'completed');
    final ticket = requireOk(
      await f.db.claimLocalDeletion(
        'fixture-delete-owned',
        (
          id: binding.key.dumpId,
          binding: binding,
          title: 'Fixture',
          eligibility: Eligibility.eligible,
          retryTicketId: null
        ),
      ),
    );
    for (final component in RecordingComponent.values) {
      await f.db.recordDeletionComponent(
        ticket.id,
        component,
        (state: ComponentState.removed, problem: null),
      );
    }
    await f.db.into(f.db.captureReservations).insert(
          CaptureReservationsCompanion.insert(
            reservationId: 'fixture-owned',
            dumpId: binding.key.dumpId,
            incarnation: binding.key.incarnation,
            locationId: binding.location.id,
            stagingPath: '${f.directory('stage')}/fixture-owned.opus',
            mode: 'meeting',
            startedAt: 1,
            state: 'committed',
            processEpoch: 'fixture-prior',
          ),
        );
    await expectLater(
      f.db.finishLocalDeletion(ticket.id),
      throwsA(isA<StorageFault>()),
    );
    expect(await f.db.getDump(binding.key.dumpId), isNotNull);
    expect(await f.db.boundRecording(binding.key.dumpId), binding);
    expect(await f.db.isRetired(binding.key.dumpId), isFalse);
  });
  test('closed capture lease never starts provider publication', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
    await File(r.stagingPath).writeAsBytes([1, 2, 3]);
    final lease = requireOk(
      await h.mutations.acquire(
        r.key.dumpId,
        UseKind.capture,
        expectedIncarnation: r.key.incarnation,
      ),
    );
    await lease.close();
    await expectLater(
      RecordingPersistence(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      ).save(
        r,
        RecordingResult(
          path: r.stagingPath,
          durationSeconds: 3,
          sizeBytes: 3,
        ),
        now: DateTime.utc(2030),
        lease: lease,
      ),
      throwsA(isA<StorageFault>()),
    );
    expect(h.backend.publishedReservations, isEmpty);
  });
  test(
      'stale process callback returns conflict without rewriting new owner journal',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    addTearDown(() async {
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET process_epoch=?',
      ['fixture-replacement-epoch'],
    );
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    final journal = await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(journal.processEpoch, 'fixture-replacement-epoch');
    expect(journal.state, 'recording');
    expect(journal.publicationJson, isNull);
    expect(h.mutations.hasActiveCapture, isFalse);
    expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
  });
  for (final malformed in ['receipt', 'metadata', 'json']) {
    test('malformed $malformed owned journal is retained with typed diagnostic',
        () async {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      addTearDown(() async {
        await recorder.dispose();
        await h.close();
      });
      await h.bootstrap();
      final c = capture(h, recorder);
      final r = requireOk(await c.start(mode: 'meeting'));
      await h.f.db.customStatement(
        "CREATE TRIGGER reject_capture BEFORE INSERT ON dumps BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
      await h.f.db.customStatement('DROP TRIGGER reject_capture');
      final journal = jsonDecode(
        (await h.f.db.select(h.f.db.captureReservations).getSingle())
            .publicationJson!,
      ) as Map<String, dynamic>;
      if (malformed == 'receipt') {
        journal['published'] = 42;
      }
      if (malformed == 'metadata') {
        (journal['metadata'] as Map)['durationSeconds'] = 99;
      }
      await h.f.db.customStatement(
        'UPDATE capture_reservations SET publication_json=?',
        [malformed == 'json' ? '{' : jsonEncode(journal)],
      );
      await h.reopen();
      await h.bootstrap();
      final result = requireOk(
        await BoundRecordingImporter(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).recoverOwnedCaptures(),
      );
      expect(result.recoveredIds, isEmpty);
      expect(result.retainedReservationIds, [r.id]);
      expect(result.problems.map((p) => p.code), contains(ProblemCode.invalid));
      expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
      expect(await h.f.db.getDump(r.key.dumpId), isNull);
    });
  }

  test(
      'uncertain commit acknowledgment reconciles matching row and cleans staging',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    await h.f.db.close();
    h.f.db = AckDb(NativeDatabase(File('${h.f.root.path}/fixture.sqlite')));
    h.resetOwners();
    addTearDown(() async {
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    final row = requireOk(await c.stopAndPersist())!;
    expect(row.id, r.key.dumpId);
    expect(await File(r.stagingPath).exists(), isFalse);
    expect(await h.f.db.hasCaptureJournal(row.id), isFalse);
  });
  for (final fault in [
    'null',
    'error',
    'path',
    'size',
    'start-error',
    'start-path',
  ]) {
    test('recorder $fault retains journal without authorizing import',
        () async {
      final h = CatalogHarness();
      final recorder = ControlledRecorder(fault);
      addTearDown(() async {
        await recorder.dispose();
        await h.close();
      });
      await h.bootstrap();
      final c = capture(h, recorder);
      final start = await c.start(mode: 'meeting');
      if (fault.startsWith('start-')) {
        expect(start, isA<Fail<CaptureReservation>>());
      } else {
        requireOk(start);
        expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
      }
      final journal =
          await h.f.db.select(h.f.db.captureReservations).getSingle();
      expect(journal.publicationJson, isNull);
      expect(h.mutations.hasActiveCapture, isFalse);
      final recovery = requireOk(
        await BoundRecordingImporter(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).recoverOwnedCaptures(),
      );
      expect(recovery.recoveredIds, isEmpty);
      expect(recovery.retainedReservationIds, [journal.reservationId]);
      expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
      expect(h.backend.publishedReservations, isEmpty);
    });
  }
  test(
      'failed publication stays fenced until actual settlement then permits default choice',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    final entered = Completer<void>();
    final finished = Completer<void>();
    addTearDown(() async {
      if (!finished.isCompleted) finished.complete();
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    h.backend.publication = (_, __) {
      entered.complete();
      return GatedIo(
        'fixture-live-publication',
        Future.value(
          const Fail(
            (code: ProblemCode.io, message: 'synthetic failed observation'),
          ),
        ),
        finished.future,
      );
    };
    final stop = c.stopAndPersist();
    await entered.future;
    final candidate = await h.choose('B');
    expect(
      await h.catalog.commitDefault(candidate, expectedRevision: 1),
      isA<Fail<DefaultFolderState>>(),
    );
    expect(h.mutations.hasActiveCapture, isTrue);
    expect(await File(r.stagingPath).exists(), isTrue);
    finished.complete();
    expect(await stop, isA<Fail<DumpRow?>>());
    expect(h.mutations.hasActiveCapture, isFalse);
    requireOk(await h.catalog.commitDefault(candidate, expectedRevision: 1));
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).state,
      'failed',
    );
  });
  for (final mismatch in ['key', 'location', 'path', 'size']) {
    test('publication receipt $mismatch mismatch cannot commit', () async {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      addTearDown(() async {
        await recorder.dispose();
        await h.close();
      });
      await h.bootstrap();
      final c = capture(h, recorder);
      final r = requireOk(await c.start(mode: 'brain_dump'));
      await h.f.audio('B', r.key.dumpId).writeAsBytes([9, 8, 7]);
      h.backend.publication = (_, __) => ImmediateIo(
            'fixture-forged-receipt',
            Ok(
              (
                binding: (
                  key: mismatch == 'key'
                      ? (
                          dumpId: 'fixture-other',
                          incarnation: r.key.incarnation
                        )
                      : r.key,
                  location: mismatch == 'location'
                      ? fileLocation('B', h.f.directory('B'))
                      : r.location,
                  audio: (
                    kind: 'file',
                    value: h.f
                        .audio(mismatch == 'path' ? 'B' : 'A', r.key.dumpId)
                        .path
                  ),
                  metadataName: '${r.key.dumpId}.meta.json'
                ),
                sizeBytes: mismatch == 'size' ? 7 : 3
              ),
            ),
          );
      expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
      expect(await h.f.db.getDump(r.key.dumpId), isNull);
      expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
      expect(await h.f.audio('B', r.key.dumpId).readAsBytes(), [9, 8, 7]);
    });
  }
  test(
      'cleanup pending survives reopen without rewriting committed semantic metadata',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    await h.f.db.close();
    final db =
        CommitHookDb(NativeDatabase(File('${h.f.root.path}/fixture.sqlite')));
    h.f.db = db;
    h.resetOwners();
    addTearDown(() async {
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    db.afterCommit = () async {
      await File(r.stagingPath).delete();
      await Directory(r.stagingPath).create();
    };
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).state,
      'committed',
    );
    expect(
      (await h.mutations.watchEligibility().first)[r.key.dumpId],
      Eligibility.publicationPending,
    );
    expect(
      await h.mutations.acquire(
        r.key.dumpId,
        UseKind.deletion,
        expectedIncarnation: r.key.incarnation,
      ),
      isA<Fail<UseLease>>(),
    );
    requireOk(
      await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 1),
    );
    await h.f.db.customStatement(
        'UPDATE dumps SET title=?, transcript=?, meeting_notes=?, transcription_error=? WHERE id=?',
        [
          'Edited title',
          'Edited words',
          'Edited meeting notes',
          'sidecar_sync_pending: manual_edit:fixture-later',
          r.key.dumpId,
        ]);
    final binding = (await h.f.db.boundRecording(r.key.dumpId))!;
    requireOk(
      await settled(
        h.backend.writeMetadata(
          binding,
          dumpMetadata((await h.f.db.getDump(r.key.dumpId))!),
          'fixture-later',
        ),
      ),
    );
    final before =
        (await h.f.db.customSelect('SELECT * FROM dumps').getSingle()).data;
    final sidecar = await h.f.metadata('A', r.key.dumpId).readAsBytes();
    final committedJournal = (await h.f.db
            .customSelect('SELECT * FROM capture_reservations')
            .getSingle())
        .data;
    final failedCleanup = requireOk(
      await BoundRecordingImporter(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      ).recoverOwnedCaptures(),
    );
    expect(failedCleanup.recoveredIds, isEmpty);
    expect(failedCleanup.problems.single.code, ProblemCode.invalid);
    expect(failedCleanup.retainedReservationIds, [r.id]);
    expect(
      (await h.f.db
              .customSelect('SELECT * FROM capture_reservations')
              .getSingle())
          .data,
      committedJournal,
    );
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps').getSingle()).data,
      before,
    );
    expect(await h.f.db.boundRecording(r.key.dumpId), binding);
    expect(await h.f.metadata('A', r.key.dumpId).readAsBytes(), sidecar);
    expect(await Directory(r.stagingPath).exists(), isTrue);
    expect(h.mutations.hasActiveCapture, isFalse);
    await Directory(r.stagingPath).delete();
    h.backend.publication = null;
    await h.reopen();
    await h.bootstrap();
    final result = requireOk(
      await BoundRecordingImporter(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      ).recoverOwnedCaptures(),
    );
    expect(result.recoveredIds, [r.key.dumpId]);
    expect(result.retainedReservationIds, isEmpty);
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps').getSingle()).data,
      before,
    );
    expect(await h.f.metadata('A', r.key.dumpId).readAsBytes(), sidecar);
    expect(
      (await h.catalog.watchDefault().first).location!.directory.path,
      h.f.directory('B'),
    );
  });
  test('target and late SQLite collisions never overwrite either recording',
      () async {
    for (final dbCollision in [false, true]) {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      try {
        await h.bootstrap();
        final c = capture(h, recorder);
        final r = requireOk(await c.start(mode: 'meeting'));
        if (dbCollision) {
          await h.f.seed(r.key.dumpId, folder: 'B', status: 'completed');
        } else {
          await h.f.audio('A', r.key.dumpId).writeAsBytes([8, 9]);
        }
        expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
        expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
        if (dbCollision) {
          expect(
            (await h.f.db.getDump(r.key.dumpId))!.transcript,
            'retained words',
          );
          expect(
            (await h.f.db.boundRecording(r.key.dumpId))!
                .location
                .directory
                .path,
            h.f.directory('B'),
          );
        } else {
          expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), [8, 9]);
          expect(await h.f.db.getDump(r.key.dumpId), isNull);
        }
      } finally {
        await recorder.dispose();
        await h.close();
      }
    }
  });
  test('interrupted recording with no known stop is retained on real reopen',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
    await File(r.stagingPath).writeAsBytes([1, 2, 3]);
    await h.reopen();
    await h.bootstrap();
    final result = requireOk(
      await BoundRecordingImporter(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      ).recoverOwnedCaptures(),
    );
    expect(result.recoveredIds, isEmpty);
    expect(result.retainedReservationIds, [r.id]);
    expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
  });
  for (final phase in ['failed', 'stopped', 'publishing']) {
    test(
        'owned $phase journal recovers across real reopen using Unix milliseconds',
        () async {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      addTearDown(() async {
        await recorder.dispose();
        await h.close();
      });
      final started = DateTime.utc(2030, 1, 2, 3, 4, 5, 123);
      h.catalog = SqliteStorageCatalog(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
        stagingDirectory: h.f.directory('stage'),
        idFactory: () => 'fixture-millis-${h.counter++}',
        now: () => started,
        canChooseDefault: true,
      );
      await h.bootstrap();
      final coordinator = DefaultRecordingCoordinator(
        db: h.f.db,
        catalog: h.catalog,
        backend: h.backend,
        mutations: h.mutations,
        recorder: recorder,
        now: () => started,
      );
      final r = requireOk(await coordinator.start(mode: 'brain_dump'));
      await h.f.db.customStatement(
        "CREATE TRIGGER fail_publish BEFORE UPDATE OF state ON capture_reservations WHEN NEW.state='publishing' BEGIN SELECT RAISE(ABORT, 'synthetic before publication'); END",
      );
      expect(await coordinator.stopAndPersist(), isA<Fail<DumpRow?>>());
      expect(
        (await h.f.db.select(h.f.db.captureReservations).getSingle()).startedAt,
        started.millisecondsSinceEpoch,
      );
      await h.f.db.customStatement('DROP TRIGGER fail_publish');
      await h.f.db
          .customStatement('UPDATE capture_reservations SET state=?', [phase]);
      await h.reopen();
      await h.bootstrap();
      final recovered = requireOk(
        await BoundRecordingImporter(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).recoverOwnedCaptures(),
      );
      expect(recovered.recoveredIds, [r.key.dumpId]);
      expect(recovered.retainedReservationIds, isEmpty);
      expect(await h.f.db.select(h.f.db.captureReservations).get(), isEmpty);
      expect(await File(r.stagingPath).exists(), isFalse);
      expect((await h.f.db.boundRecording(r.key.dumpId))!.location, r.location);
      expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), [1, 2, 3]);
      expect(h.backend.publishedReservations.last.startedAt, started);
    });
  }
  for (final failDatabase in [false, true]) {
    test(
        'capture pins root and retains staging until durable DB commit, failure $failDatabase',
        () async {
      final h = CatalogHarness();
      final recorder = FileRecorder();
      addTearDown(() async {
        await recorder.dispose();
        await h.close();
      });
      await h.bootstrap();
      final coordinator = DefaultRecordingCoordinator(
        db: h.f.db,
        catalog: h.catalog,
        backend: h.backend,
        mutations: h.mutations,
        recorder: recorder,
        now: () => DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
      );
      final old = await h.catalog.watchDefault().first;
      final reservation = requireOk(await coordinator.start(mode: 'meeting'));
      expect(recorder.currentPath, reservation.stagingPath);
      final candidate = await h.choose('B');
      final busy = await h.catalog
          .commitDefault(candidate, expectedRevision: old.revision);
      expect(busy, isA<Fail<DefaultFolderState>>());
      expect((busy as Fail<DefaultFolderState>).problem.code, ProblemCode.busy);
      if (failDatabase) {
        await h.f.db.customStatement(
          "CREATE TRIGGER fail_capture BEFORE INSERT ON dumps BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END",
        );
      }
      final outcome = await coordinator.stopAndPersist();
      if (failDatabase) {
        expect(outcome, isA<Fail<DumpRow?>>());
        expect(await File(reservation.stagingPath).readAsBytes(), [1, 2, 3]);
        expect(await h.f.db.getDump(reservation.key.dumpId), isNull);
        final saved =
            await h.f.db.select(h.f.db.captureReservations).getSingle();
        expect(saved.state, 'failed');
        expect(saved.stagingPath, reservation.stagingPath);
      } else {
        final row = requireOk(outcome)!;
        expect(row.mode, 'meeting');
        expect(row.syncStatus, 'local_only');
        expect(
          (await h.f.db.boundRecording(row.id))!.location,
          reservation.location,
        );
        expect(await File(reservation.stagingPath).exists(), isFalse);
        expect(await h.f.db.select(h.f.db.captureReservations).get(), isEmpty);
      }
      expect(
        await h.f.audio('A', reservation.key.dumpId).readAsBytes(),
        [1, 2, 3],
      );
      expect(await h.f.audio('B', reservation.key.dumpId).exists(), isFalse);
    });
  }
  test('committed staging journal prevents deletion until owned cleanup',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final binding =
        await h.f.seed('fixture-cleanup-pending', status: 'completed');
    await h.bootstrap();
    await h.f.db.customStatement(
        'INSERT INTO capture_reservations(reservation_id,dump_id,incarnation,location_id,staging_path,mode,started_at,state,process_epoch,publication_json) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [
          'fixture-journal',
          binding.key.dumpId,
          binding.key.incarnation,
          binding.location.id,
          '${h.f.directory('stage')}/fixture-cleanup-pending.opus',
          'brain_dump',
          1893456000123,
          'committed',
          h.mutations.processEpoch,
          '{}',
        ]);
    final result = await h.f.db.claimLocalDeletion(
      'fixture-delete',
      (
        id: binding.key.dumpId,
        binding: binding,
        title: 'fixture',
        eligibility: Eligibility.eligible,
        retryTicketId: null
      ),
    );
    expect(result, isA<Fail<DeletionTicket>>());
    expect((result as Fail<DeletionTicket>).problem.code, ProblemCode.busy);
    expect(
      (await h.mutations.watchEligibility().first)[binding.key.dumpId],
      Eligibility.publicationPending,
    );
    expect(await h.f.db.boundRecording(binding.key.dumpId), binding);
  });
}
