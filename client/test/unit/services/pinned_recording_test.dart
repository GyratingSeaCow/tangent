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
import '../../support/scripted_storage_backend.dart';

class AckDb extends LocalDb {
  AckDb(super.executor) : super.forTesting();
  @override
  Future<T> commitOwnedCapture<T>(Future<T> Function() action) async {
    await super.commitOwnedCapture(action);
    throw SqliteException(10, 'synthetic committed but acknowledgment lost');
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

void main() {
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
    h.backend.publication = (_, __) => ImmediateIo('fixture-first-failure',
        const Fail((code: ProblemCode.io, message: 'synthetic')),);
    expect(await c.stopAndPersist(), isA<Fail<DumpRow?>>());
    h.backend.publication = (r, metadata) {
      published.complete();
      return h.f.backend.publishCapture(r, metadata);
    };
    admission = h.mutations.catalogAdmission(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    recovery = BoundRecordingImporter(
            db: h.f.db, backend: h.backend, mutations: h.mutations,)
        .recoverOwnedCaptures();
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
    addTearDown(() async {
      await recorder.dispose();
      await h.close();
    });
    await h.bootstrap();
    final c = capture(h, recorder);
    final r = requireOk(await c.start(mode: 'meeting'));
    h.backend.publication = (reservation, metadata) => fixtureIo(() async {
          final result =
              await settled(h.f.backend.publishCapture(reservation, metadata));
          await File(r.stagingPath).delete();
          await Directory(r.stagingPath).create();
          return result;
        });
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
        'UPDATE dumps SET title=?, transcript=?, transcription_error=? WHERE id=?',
        [
          'Edited title',
          'Edited words',
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
