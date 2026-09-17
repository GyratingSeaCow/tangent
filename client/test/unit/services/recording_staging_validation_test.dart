// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';
import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

/// Reproduces the on-device failure "Invalid owned staging source": the
/// installed build stages valid opus audio but save() rejects it when the
/// staging directory path is a symlink (Android /data/user/0 vs /data/data)
/// or when the encoder finalizes bytes after stop() reported sizeBytes.
final class SymlinkedStagingHarness {
  static int _next = 0;
  final int fixtureId = _next++;
  final f = StorageFixture.create();
  final backend = ScriptedStorageBackend();
  late DefaultRecordingMutationCoordinator mutations;
  late SqliteStorageCatalog catalog;
  late final String linkedStagingDir;
  int counter = 0;

  SymlinkedStagingHarness() {
    // The real directory is f.root/stage; reservations hand out paths through
    // a symlinked alias, exactly like getTemporaryDirectory() returning the
    // /data/user/0 alias of /data/data on Android.
    linkedStagingDir = p.join(f.root.path, 'stage-alias');
    Link(linkedStagingDir).createSync(f.directory('stage'));
    resetOwners();
  }

  void resetOwners() {
    mutations = DefaultRecordingMutationCoordinator(db: f.db);
    catalog = SqliteStorageCatalog(
      db: f.db,
      backend: backend,
      mutations: mutations,
      stagingDirectory: linkedStagingDir,
      idFactory: () => 'fixture-symlink-$fixtureId-${counter++}',
      now: () => DateTime.utc(2030),
      canChooseDefault: true,
    );
  }

  Future<void> bootstrap() async {
    requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: f.directory('A'),
      ),
    );
  }

  Future<void> reopen() async {
    await backend.drain();
    await mutations.drain();
    await f.reopen();
    resetOwners();
  }

  Future<void> close() async {
    await backend.drain();
    await mutations.drain();
    await f.close();
  }
}

Future<DumpRow> saveWith(
  DefaultRecordingMutationCoordinator mutations,
  LocalDb db,
  StorageBackend backend,
  CaptureReservation r,
  int reportedSizeBytes,
) async {
  final lease = requireOk(
    await mutations.acquire(
      r.key.dumpId,
      UseKind.capture,
      expectedIncarnation: r.key.incarnation,
    ),
  );
  try {
    return await mutations.serialize(
      r.key,
      () => RecordingPersistence(
        db: db,
        backend: backend,
        mutations: mutations,
      ).save(
        r,
        RecordingResult(
          path: r.stagingPath,
          durationSeconds: 3,
          sizeBytes: reportedSizeBytes,
        ),
        now: DateTime.utc(2030, 1, 2, 3, 4, 5),
        lease: lease,
      ),
    );
  } finally {
    await lease.close();
  }
}

void main() {
  final links = () {
    try {
      final probe = Directory.systemTemp.createTempSync('tangent-linkprobe-');
      try {
        Link(p.join(probe.path, 'l')).createSync(probe.path);
        return true;
      } finally {
        probe.deleteSync(recursive: true);
      }
    } on FileSystemException {
      return false; // Windows without developer mode cannot create symlinks.
    }
  }();

  test('staged audio under a symlinked staging directory still saves',
      () async {
    if (!links) {
      markTestSkipped('symlinks unavailable on this host');
      return;
    }
    final h = SymlinkedStagingHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    expect(p.dirname(r.stagingPath), h.linkedStagingDir);
    await File(r.stagingPath).writeAsBytes([0x4f, 0x67, 0x67, 0x53, 1],
        flush: true,);
    // The device defect: _staging() faulted ProblemCode.invalid with
    // 'Invalid owned staging source' for an aliased staging directory.
    // On Android the SAF backend has no host filesystem publish; on a
    // Windows/Linux HOST the hardened capture I/O separately rejects
    // reparse-point ancestors during publication (a deliberate property
    // this fix must not weaken). Assert the original fault is gone and
    // classify the only tolerated host-side outcome explicitly.
    try {
      final row = await saveWith(h.mutations, h.f.db, h.backend, r, 5);
      expect(row.audioSizeBytes, 5);
      expect(await h.f.db.getDump(row.id), isNotNull);
      expect(await h.f.audio('A', row.id).readAsBytes(), hasLength(5));
    } on StorageFault catch (e) {
      expect(
        e.problem.message,
        isNot('Invalid owned staging source'),
        reason: 'staging validation must accept the aliased owned directory',
      );
      expect(e.problem.code, ProblemCode.conflict);
      expect(
        e.problem.message,
        'Capture object is a reparse point or wrong type',
        reason: 'only the host publish-path ancestor hardening may reject',
      );
      expect(await File(r.stagingPath).exists(), isTrue,
          reason: 'failure paths preserve raw recordings',);
    }
  });

  test('encoder bytes flushed after stop() persist the on-disk length',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    // The recorder reported 3 bytes at stop; the opus writer finalized two
    // more before validation — the authoritative on-disk length must win.
    await File(r.stagingPath)
        .writeAsBytes([0x4f, 0x67, 0x67, 0x53, 1], flush: true);
    final row = await saveWith(h.mutations, h.f.db, h.backend, r, 3);
    expect(row.audioSizeBytes, 5);
    expect(await h.f.audio('A', row.id).readAsBytes(), hasLength(5));
    final entries = requireOk(
      await settled(h.backend.listRecordingsAt(r.location)),
    );
    expect(entries.single.sizeBytes, 5);
    expect(entries.single.metadata?['audioSizeBytes'], 5);
  });

  test('shrunken staging below the recorder-reported size still faults',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    await File(r.stagingPath).writeAsBytes([1, 2], flush: true);
    await expectLater(
      saveWith(h.mutations, h.f.db, h.backend, r, 3),
      throwsA(
        isA<StorageFault>()
            .having((e) => e.problem.code, 'code', ProblemCode.invalid)
            .having(
              (e) => e.problem.message,
              'message',
              'Invalid owned staging source',
            ),
      ),
    );
    expect(await h.f.db.getDump(r.key.dumpId), isNull);
    expect(await File(r.stagingPath).exists(), isTrue,
        reason: 'failure paths preserve raw recordings',);
  });

  test('a staging entry that is itself a symlink stays rejected', () async {
    if (!links) {
      markTestSkipped('symlinks unavailable on this host');
      return;
    }
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    final foreign = File(p.join(h.f.root.path, 'foreign.opus'));
    await foreign.writeAsBytes([1, 2, 3], flush: true);
    Link(r.stagingPath).createSync(foreign.path);
    await expectLater(
      saveWith(h.mutations, h.f.db, h.backend, r, 3),
      throwsA(
        isA<StorageFault>()
            .having((e) => e.problem.code, 'code', ProblemCode.invalid)
            .having(
              (e) => e.problem.message,
              'message',
              'Invalid owned staging source',
            ),
      ),
    );
    expect(await h.f.db.getDump(r.key.dumpId), isNull);
  });

  test(
      'interrupted reservation with intact symlink-staged file recovers into a '
      'dump row on next launch without re-recording', () async {
    if (!links) {
      markTestSkipped('symlinks unavailable on this host');
      return;
    }
    final h = SymlinkedStagingHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    final audio = [0x4f, 0x67, 0x67, 0x53, 9, 9];
    await File(r.stagingPath).writeAsBytes(audio, flush: true);
    // The first save attempt dies before any publication I/O — the process
    // was interrupted mid-capture; only the stopped journal was persisted.
    h.backend.publication = (reservation, preparation) => ImmediateIo(
          'fixture-interrupted-publish',
          const Fail<PublishedCapture>(
            (code: ProblemCode.io, message: 'fixture process interrupted'),
          ),
        );
    await expectLater(
      saveWith(h.mutations, h.f.db, h.backend, r, audio.length),
      throwsA(isA<StorageFault>().having(
        (e) => e.problem,
        'problem',
        anyOf(
          // The scripted publication failure (the intended interruption)...
          (code: ProblemCode.io, message: 'fixture process interrupted'),
          // ...or, on hosts whose hardened capture I/O rejects reparse-point
          // ancestors before publication, that earlier deliberate guard.
          (
            code: ProblemCode.conflict,
            message: 'Capture object is a reparse point or wrong type'
          ),
        ),
      ),),
    );
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET state=? WHERE reservation_id=?',
      ['interrupted', r.id],
    );
    // Fresh app launch: new DB connection, new coordinator, real backend.
    await h.reopen();
    await h.mutations
        .restoreFences(unsettled: await h.f.backend.unsettledUses());
    final recovered = await RecordingPersistence(
      db: h.f.db,
      backend: h.f.backend,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    // The corrected _staging never rejects the intact aliased staging file:
    // the historical 'Invalid owned staging source' fault must be gone.
    expect(
      recovered.problems.map((problem) => problem.message),
      isNot(contains('Invalid owned staging source')),
    );
    if (recovered.problems.isEmpty) {
      expect(recovered.recoveredIds, [r.key.dumpId]);
      final row = await h.f.db.getDump(r.key.dumpId);
      expect(row, isNotNull);
      expect(row!.audioSizeBytes, audio.length);
      expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), audio);
    } else {
      // Host-only publish-path ancestor hardening; staged audio preserved.
      expect(
        recovered.problems.single.message,
        'Capture object is a reparse point or wrong type',
      );
      expect(recovered.recoveredIds, isEmpty);
      expect(await File(r.stagingPath).readAsBytes(), audio,
          reason: 'failure paths preserve raw recordings',);
    }
  });
}
