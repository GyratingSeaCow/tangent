// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

void main() {
  test(
      'failed reservation with a live capture worker blocks default until actual settlement',
      () async {
    final h = CatalogHarness();
    final actual = Completer<void>();
    addTearDown(() async {
      if (!actual.isCompleted) actual.complete();
      await h.close();
    });
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    final reservation =
        requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
    final lease = requireOk(
      await h.mutations.acquire(
        reservation.key.dumpId,
        UseKind.capture,
        expectedIncarnation: reservation.key.incarnation,
      ),
    );
    final failed = await h.mutations.runIo(
      lease,
      () => GatedIo(
        'fixture-worker',
        Future.value(
          const Fail<void>(
            (code: ProblemCode.io, message: 'synthetic result failure'),
          ),
        ),
        actual.future,
      ),
    );
    expect(failed, isA<Fail<void>>());
    final closing = lease.close();
    await h.f.db
        .customStatement("UPDATE capture_reservations SET state='failed'");
    final candidate = await h.choose('B');
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: state.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.busy,
    );
    actual.complete();
    await closing;
    requireOk(
      await h.catalog
          .commitDefault(candidate, expectedRevision: state.revision),
    );
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).locationId,
      reservation.location.id,
    );
  });
  test(
      'reservation excludes claimed IDs, rolls back persistence failure and creates no staging artifact',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.seed('fixture-existing');
    await h.bootstrap();
    final ids = [
      'fixture-existing',
      'fixture-new',
      'fixture-new-inc',
      'fixture-next',
      'fixture-next-inc',
    ].iterator;
    final catalog = SqliteStorageCatalog(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
      stagingDirectory: h.f.directory('stage'),
      idFactory: () {
        expect(ids.moveNext(), true);
        return ids.current;
      },
      now: () => DateTime.utc(2030),
      canChooseDefault: true,
    );
    await h.f.db.customStatement(
      "CREATE TRIGGER reject_reserve BEFORE INSERT ON capture_reservations BEGIN SELECT RAISE(ABORT, 'synthetic reservation failure'); END",
    );
    expect(
      (await catalog.reserveCapture(mode: 'brain_dump') as Fail).problem.code,
      ProblemCode.persistence,
    );
    expect(await h.f.db.select(h.f.db.captureReservations).get(), isEmpty);
    expect(await Directory(h.f.directory('stage')).list().toList(), isEmpty);
    await h.f.db.customStatement('DROP TRIGGER reject_reserve');
    final reservation =
        requireOk(await catalog.reserveCapture(mode: 'brain_dump'));
    expect(reservation.key.dumpId, 'fixture-next');
    expect(reservation.key.incarnation, 'fixture-next-inc');
    expect(await File(reservation.stagingPath).exists(), false);
    expect((await h.f.db.listDumps()).single.id, 'fixture-existing');
  });
  test(
      'watchDefault emits the committed pointer and revision to a live observer',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final initial = Completer<DefaultFolderState>();
    final changed = Completer<DefaultFolderState>();
    final subscription = h.catalog.watchDefault().listen((state) {
      if (!initial.isCompleted) initial.complete(state);
      if (state.location?.directory.path == h.f.directory('B') &&
          !changed.isCompleted) {
        changed.complete(state);
      }
    });
    addTearDown(subscription.cancel);
    final before = await initial.future;
    final committed = requireOk(
      await h.catalog.commitDefault(
        await h.choose('B'),
        expectedRevision: before.revision,
      ),
    );
    expect(await changed.future.timeout(const Duration(seconds: 5)), committed);
  });

  test(
      'throwing failed probe remains fenced until actual settlement and permits fresh choice after',
      () async {
    final h = CatalogHarness();
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await h.close();
    });
    await h.bootstrap();
    final original = await h.catalog.watchDefault().first;
    h.backend.choice = Ok(fileLocation('B', h.f.directory('B')));
    h.backend.probe = (_, __) {
      entered.complete();
      return GatedIo(
        'throwing-probe',
        Future.error(
          const StorageFault(
            (code: ProblemCode.io, message: 'synthetic result failure'),
          ),
        ),
        release.future,
      );
    };
    var finished = false;
    final work = h.catalog.chooseFolderCandidate().then((r) {
      finished = true;
      return r;
    });
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    release.complete();
    expect(await work, isA<Fail<FolderCandidate?>>());
    expect(await h.catalog.watchDefault().first, original);
    h.backend.probe = null;
    expect(await h.choose('B'), isNotNull);
  });

  test(
      'capture pins destination and serializes default commit until settled failure',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    final candidate = await h.choose('B');
    final reservation =
        requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    expect(reservation.location, state.location);
    final stored = await h.f.db.select(h.f.db.captureReservations).getSingle();
    expect(stored.processEpoch, h.mutations.processEpoch);
    expect(stored.state, 'reserved');
    expect(stored.stagingPath, reservation.stagingPath);
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: state.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.busy,
    );
    await h.f.db
        .customStatement("UPDATE capture_reservations SET state='failed'");
    final replacement = await h.choose('B');
    requireOk(
      await h.catalog
          .commitDefault(replacement, expectedRevision: state.revision),
    );
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).locationId,
      reservation.location.id,
    );
  });

  test('old bound recording works independently of missing default', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final binding = await h.f.seed('fixture-independent');
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    requireOk(
      await h.catalog
          .commitDefault(await h.choose('B'), expectedRevision: state.revision),
    );
    await Directory(h.f.directory('B')).delete();
    expect((await h.catalog.watchDefault().first).available, false);
    expect(
      await h.catalog.reserveCapture(mode: 'brain_dump'),
      isA<Fail<CaptureReservation>>(),
    );
    expect(
      requireOk(await h.catalog.resolveRecording(binding.key.dumpId)),
      binding,
    );
  });
  test(
      'stale revision, forged location, consumed token and same directory are checked atomically',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.seed('fixture-stable');
    await h.bootstrap();
    final binding = await h.f.db.boundRecording('fixture-stable');
    final state = await h.catalog.watchDefault().first;
    final candidate = await h.choose('B');
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: state.revision - 1,
      ) as Fail)
          .problem
          .code,
      ProblemCode.staleRevision,
    );
    expect(
      (await h.catalog.commitDefault(
        (
          token: candidate.token,
          location: fileLocation('A', h.f.directory('A'))
        ),
        expectedRevision: state.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.conflict,
    );
    final committed = requireOk(
      await h.catalog
          .commitDefault(candidate, expectedRevision: state.revision),
    );
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: committed.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.conflict,
    );
    h.backend.choice =
        Ok(fileLocation('fixture-another-label', h.f.directory('B')));
    final same = requireOk(await h.catalog.chooseFolderCandidate())!;
    final unchanged = requireOk(
      await h.catalog.commitDefault(same, expectedRevision: committed.revision),
    );
    expect(unchanged.location, committed.location);
    expect(unchanged.revision, committed.revision);
    expect(await h.f.db.boundRecording('fixture-stable'), binding);
  });
  test(
      'uncommitted validated candidate is interrupted across real DB reopen and process epoch',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final original = await h.catalog.watchDefault().first;
    final candidate = await h.choose('B');
    final epoch = h.mutations.processEpoch;
    await h.reopen();
    expect(h.mutations.processEpoch, isNot(epoch));
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: original.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.conflict,
    );
    expect(await h.catalog.watchDefault().first, original);
    final saved = jsonDecode(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .candidateJson!,
    ) as Map;
    expect(saved['phase'], 'interrupted');
    expect(saved['owned'], isNotEmpty);
  });
  test(
      'two pending chooser callbacks cannot let a late older result replace the newer candidate',
      () async {
    final h = CatalogHarness();
    final firstPicker = Completer<Outcome<StorageLocation?>>();
    final secondPicker = Completer<Outcome<StorageLocation?>>();
    final firstEntered = Completer<void>();
    final secondEntered = Completer<void>();
    var calls = 0;
    addTearDown(() async {
      if (!firstPicker.isCompleted) firstPicker.complete(const Ok(null));
      if (!secondPicker.isCompleted) secondPicker.complete(const Ok(null));
      await h.close();
    });
    await h.bootstrap();
    h.backend.picker = () {
      if (calls++ == 0) {
        firstEntered.complete();
        return firstPicker.future;
      }
      secondEntered.complete();
      return secondPicker.future;
    };
    final first = h.catalog.chooseFolderCandidate();
    await firstEntered.future;
    final second = h.catalog.chooseFolderCandidate();
    await secondEntered.future;
    secondPicker.complete(Ok(fileLocation('B', h.f.directory('B'))));
    final newest = requireOk(await second)!;
    firstPicker.complete(Ok(fileLocation('A', h.f.directory('A'))));
    expect((await first as Fail).problem.code, ProblemCode.conflict);
    final state = await h.catalog.watchDefault().first;
    requireOk(
      await h.catalog.commitDefault(newest, expectedRevision: state.revision),
    );
    expect(
      (await h.catalog.watchDefault().first).location!.directory.path,
      h.f.directory('B'),
    );
  });
  test(
      'probe receipt persists exact paths and unknown cleanup never changes readiness',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    final receipt = [
      (kind: 'file', value: '${h.f.directory('B')}/fixture-owned-A'),
      (kind: 'file', value: '${h.f.directory('B')}/fixture-owned-B'),
    ];
    h.backend.choice = Ok(fileLocation('B', h.f.directory('B')));
    h.backend.probe =
        (_, __) => ImmediateIo('probe', Ok((owned: receipt, cleaned: false)));
    expect(
      (await h.catalog.chooseFolderCandidate() as Fail).problem.code,
      ProblemCode.io,
    );
    final saved = jsonDecode(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .candidateJson!,
    ) as Map;
    expect(
      (saved['owned'] as List).map((e) => e['value']).toList(),
      receipt.map((e) => e.value).toList(),
    );
    expect(saved['cleaned'], false);
    expect(saved['phase'], 'failed');
    expect(await h.catalog.watchDefault().first, state);
    h.backend.probe = null;
    await h.choose('B');
    final next = jsonDecode(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .candidateJson!,
    ) as Map;
    expect((next['retained'] as List).single['owned'], saved['owned']);
    expect(h.backend.componentCalls, 0);
  });
  test(
      'probe phase durable before I/O and result success cannot validate before actual settlement',
      () async {
    final h = CatalogHarness();
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await h.close();
    });
    await h.bootstrap();
    h.backend.choice = Ok(fileLocation('B', h.f.directory('B')));
    String? token;
    h.backend.probe = (t, _) {
      token = t;
      entered.complete();
      return GatedIo(
        'gated-probe',
        Future.value(const Ok((owned: <AudioLocator>[], cleaned: true))),
        release.future,
      );
    };
    var done = false;
    final choice = h.catalog.chooseFolderCandidate().then((v) {
      done = true;
      return v;
    });
    await entered.future;
    final state = await h.f.db.select(h.f.db.storageCatalogStates).getSingle();
    final saved = jsonDecode(state.candidateJson!) as Map;
    expect(saved['phase'], 'probing');
    expect(saved['token'], token);
    expect(saved['processEpoch'], h.mutations.processEpoch);
    expect(done, false);
    release.complete();
    expect(requireOk(await choice), isNotNull);
  });
  test(
      'inventory failure never opens coordinator or permits catalog mutation, retry restores real uses',
      () async {
    final h = CatalogHarness();
    final settled = Completer<void>();
    addTearDown(() async {
      if (!settled.isCompleted) settled.complete();
      await h.close();
    });
    h.backend.inventory = () async => throw const StorageFault(
          (
            code: ProblemCode.unavailable,
            message: 'native inventory unavailable'
          ),
        );
    expect(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
      isA<Fail<BootstrapResult>>(),
    );
    expect(h.backend.captureCalls, 0);
    expect(
      (await h.mutations.acquire(
        'fixture-not-admitted',
        UseKind.capture,
        expectedIncarnation: 'fixture-inc',
      ) as Fail)
          .problem
          .code,
      ProblemCode.unavailable,
    );
    h.backend.inventory = () async => [
          (
            key: (dumpId: 'fixture-native', incarnation: 'fixture-native-inc'),
            kind: UseKind.capture,
            settled: settled.future
          ),
        ];
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    final candidate = await h.choose('B');
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: state.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.busy,
    );
    expect(
      (await h.catalog.reserveCapture(mode: 'meeting') as Fail).problem.code,
      ProblemCode.busy,
    );
    settled.complete();
    await h.mutations.drain();
    requireOk(
      await h.catalog
          .commitDefault(candidate, expectedRevision: state.revision),
    );
  });
  test(
      'settled interrupted reservation permits default but reobserved native capture still blocks it',
      () async {
    final h = CatalogHarness();
    final settled = Completer<void>();
    addTearDown(() async {
      if (!settled.isCompleted) settled.complete();
      await h.close();
    });
    await h.bootstrap();
    final reservation =
        requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
    await h.reopen();
    h.backend.inventory = () async => [
          (
            key: reservation.key,
            kind: UseKind.capture,
            settled: settled.future
          ),
        ];
    final state = await h.catalog.watchDefault().first;
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).state,
      'interrupted',
    );
    final candidate = await h.choose('B');
    expect(
      (await h.catalog.commitDefault(
        candidate,
        expectedRevision: state.revision,
      ) as Fail)
          .problem
          .code,
      ProblemCode.busy,
    );
    settled.complete();
    await h.mutations.drain();
    requireOk(
      await h.catalog
          .commitDefault(candidate, expectedRevision: state.revision),
    );
    expect(
      (await h.f.db.select(h.f.db.captureReservations).getSingle()).locationId,
      reservation.location.id,
    );
  });
  for (final reserveFirst in [true, false]) {
    test(
        'same-time capture and default admission serialize (reserve first $reserveFirst)',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      final state = await h.catalog.watchDefault().first;
      final candidate = await h.choose('B');
      late Future<Outcome<CaptureReservation>> reservation;
      late Future<Outcome<DefaultFolderState>> commit;
      if (reserveFirst) {
        reservation = h.catalog.reserveCapture(mode: 'brain_dump');
        commit = h.catalog
            .commitDefault(candidate, expectedRevision: state.revision);
      } else {
        commit = h.catalog
            .commitDefault(candidate, expectedRevision: state.revision);
        reservation = h.catalog.reserveCapture(mode: 'brain_dump');
      }
      final saved = requireOk(await reservation);
      final change = await commit;
      if (reserveFirst) {
        expect((change as Fail).problem.code, ProblemCode.busy);
        expect(saved.location, state.location);
      } else {
        expect(saved.location, requireOk(change).location);
      }
    });
  }
  test('lost activity and desktop unsupported leave default unchanged',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final state = await h.catalog.watchDefault().first;
    h.backend.choice =
        const Fail((code: ProblemCode.interrupted, message: 'lost activity'));
    expect(
      (await h.catalog.chooseFolderCandidate() as Fail).problem.code,
      ProblemCode.interrupted,
    );
    expect(await h.catalog.watchDefault().first, state);
    h.resetOwners(canChooseDefault: false);
    expect(
      (await h.catalog.chooseFolderCandidate() as Fail).problem.code,
      ProblemCode.unsupported,
    );
    expect((await h.catalog.watchDefault().first).canChooseDefault, false);
    expect(
      requireOk(await h.catalog.reserveCapture(mode: 'brain_dump')).location,
      state.location,
    );
  });
  test(
      'cancel, failed validation, failed commit and real restart preserve authority',
      () async {
    final f = StorageFixture.create();
    await f.seed('fixture-old');
    final backend = ScriptedStorageBackend();
    var mutations = DefaultRecordingMutationCoordinator(db: f.db);
    var counter = 0;
    SqliteStorageCatalog catalog() => SqliteStorageCatalog(
          db: f.db,
          backend: backend,
          mutations: mutations,
          stagingDirectory: f.directory('stage'),
          idFactory: () => 'fixture-token-${counter++}',
          now: () => DateTime.utc(2030),
          canChooseDefault: true,
        );
    addTearDown(() async {
      await backend.drain();
      await mutations.drain();
      await f.close();
    });
    final first = catalog();
    requireOk(
      await first.bootstrapLegacyBindings(
        filesystemLegacyDirectory: f.directory('A'),
      ),
    );
    final binding = await f.db.boundRecording('fixture-old');
    final original = await first.watchDefault().first;
    expect(requireOk(await first.chooseFolderCandidate()), isNull);
    expect(await first.watchDefault().first, original);
    backend.choice = Ok(fileLocation('B', f.directory('B')));
    backend.validationFails = true;
    expect(await first.chooseFolderCandidate(), isA<Fail<FolderCandidate?>>());
    expect(await first.watchDefault().first, original);
    backend.validationFails = false;
    final candidate = requireOk(await first.chooseFolderCandidate())!;
    await f.db.customStatement(
      '''CREATE TRIGGER reject_default BEFORE UPDATE ON storage_catalog_state WHEN NEW.default_location_id IS NOT OLD.default_location_id BEGIN SELECT RAISE(ABORT, 'synthetic commit failure'); END''',
    );
    expect(
      await first.commitDefault(
        candidate,
        expectedRevision: original.revision,
      ),
      isA<Fail<DefaultFolderState>>(),
    );
    expect((await first.watchDefault().first).location, original.location);
    await f.db.customStatement('DROP TRIGGER reject_default');
    final replacement = requireOk(await first.chooseFolderCandidate())!;
    final committed = requireOk(
      await first.commitDefault(
        replacement,
        expectedRevision: original.revision,
      ),
    );
    expect(committed.location!.directory.path, f.directory('B'));
    expect(committed.revision, original.revision + 1);
    await backend.drain();
    await mutations.drain();
    await f.reopen();
    mutations = DefaultRecordingMutationCoordinator(db: f.db);
    final restarted = catalog();
    requireOk(
      await restarted.bootstrapLegacyBindings(
        filesystemLegacyDirectory: f.directory('B'),
      ),
    );
    final restored = await restarted.watchDefault().first;
    expect(restored.location, committed.location);
    expect(restored.revision, committed.revision);
    expect(await f.db.boundRecording('fixture-old'), binding);
    expect(await f.db.listDumps(), hasLength(1));
    expect(backend.captureCalls, 1);
    expect(backend.inventoryCalls, 2);
  });
}
