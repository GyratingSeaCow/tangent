// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

class _Connectivity extends Mock implements ConnectivityService {}

class _Client extends Fake implements TranscriptionClient {
  _Client(this.gate);
  final String gate;
  final entered = Completer<void>(), release = Completer<void>();
  int creates = 0;
  final uploads = <List<int>>[];
  @override
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async {
    creates++;
    if (gate == 'create') {
      entered.complete();
      await release.future;
    }
    return id;
  }

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    uploads.add(List.of(audioBytes));
    if (gate == 'upload') {
      entered.complete();
      await release.future;
    }
  }
}

class _DeniedRead extends ScriptedStorageBackend {
  @override
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding) =>
      ImmediateIo(
        'fixture-denied',
        const Fail(
          (code: ProblemCode.denied, message: 'synthetic permission denied'),
        ),
      );
}

void main() {
  late StorageFixture f;
  late DefaultRecordingMutationCoordinator mutations;
  late ScriptedStorageBackend backend;
  late _Client client;
  late SyncEngine engine;
  Future<void> setup(String gate, {bool denied = false}) async {
    f = StorageFixture.create();
    backend = denied ? _DeniedRead() : ScriptedStorageBackend();
    mutations = DefaultRecordingMutationCoordinator(db: f.db);
    client = _Client(gate);
    final conn = _Connectivity();
    when(() => conn.currentStatus())
        .thenAnswer((_) async => ConnectivityStatus.wifi);
    engine = SyncEngine(
      db: f.db,
      recordingAccess: BoundRecordingAccess(
        db: f.db,
        backend: backend,
        mutations: mutations,
      ),
      mutations: mutations,
      client: client,
      connectivity: conn,
      // These cases exercise the OPT-IN BACKUP path: they assert that
      // syncNow actually uploads. keepRecordingsOnDeviceOnly defaults to
      // true (recordings stay on the device unless the user opts in), so
      // backup must be enabled explicitly here. Do not "fix" these by
      // relaxing the upload assertions — they guard real transport
      // behaviour, including failure and cancellation handling.
      settings: SettingsStore(keepRecordingsOnDeviceOnly: false),
    );
    addTearDown(() async {
      if (!client.release.isCompleted) client.release.complete();
      engine.dispose();
      await backend.drain();
      await mutations.drain();
      await f.close();
    });
    await mutations.restoreFences(unsettled: await backend.unsettledUses());
  }

  test(
      'sync preserves denied read diagnostic rather than fabricating empty audio',
      () async {
    await setup('', denied: true);
    final a = await f.seed('fixture-sync-denied', sync: 'pending');
    await engine.syncNow();
    expect(client.creates, 0);
    expect(client.uploads, isEmpty);
    final row = (await f.db.getDump(a.key.dumpId))!;
    expect(row.syncStatus, 'failed');
    expect(row.syncAttempts, 1);
    expect(row.lastSyncError, contains('synthetic permission denied'));
    expect(engine.lastError, contains('synthetic permission denied'));
  });
  for (final boundary in ['create', 'upload']) {
    test(
        'sync retains actual $boundary future past caller timeout and disposal',
        () async {
      await setup(boundary);
      final a = await f.seed('fixture-sync-race', sync: 'pending');
      await f.audio('B', a.key.dumpId).writeAsBytes([9]);
      final syncing = engine.syncNow();
      await client.entered.future;
      expect((await f.db.getDump(a.key.dumpId))!.syncStatus, 'pending');
      await expectLater(
        syncing.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      engine.dispose();
      expect(
        await mutations.acquire(a.key.dumpId, UseKind.deletion),
        isA<Fail<UseLease>>(),
      );
      client.release.complete();
      await syncing;
      await mutations.drain();
      expect(client.creates, 1);
      expect(
        client.uploads,
        boundary == 'create'
            ? isEmpty
            : [
                [1, 2, 3],
              ],
      );
      expect((await f.db.getDump(a.key.dumpId))!.syncStatus, 'pending');
      final deletion =
          requireOk(await mutations.acquire(a.key.dumpId, UseKind.deletion));
      await deletion.close();
      expect(await f.audio('B', a.key.dumpId).readAsBytes(), [9]);
    });
  }
  test('sync checks captured incarnation before subsequent transport',
      () async {
    await setup('create');
    final a = await f.seed('fixture-sync-foreign', sync: 'pending');
    final syncing = engine.syncNow();
    await client.entered.future;
    await f.db.customStatement(
      'UPDATE recording_bindings SET incarnation=? WHERE dump_id=?',
      ['fixture-foreign', a.key.dumpId],
    );
    client.release.complete();
    await syncing;
    expect(client.uploads, isEmpty);
    expect((await f.db.getDump(a.key.dumpId))!.syncStatus, 'pending');
    expect(engine.lastError, contains('no longer available'));
  });
  test(
      'sync privacy excludes meeting and local-only while bound pending uploads',
      () async {
    await setup('');
    await f.seed('fixture-private-local');
    final meeting = await f.seed('fixture-private-meeting', sync: 'pending');
    await f.db.customStatement(
      "UPDATE dumps SET mode='meeting' WHERE id=?",
      [meeting.key.dumpId],
    );
    final a = await f.seed('fixture-sync-ok', sync: 'pending');
    await engine.syncNow();
    expect(client.creates, 1);
    expect(client.uploads, [
      [1, 2, 3],
    ]);
    expect((await f.db.getDump(a.key.dumpId))!.syncStatus, 'synced');
    expect((await f.db.getDump(meeting.key.dumpId))!.syncStatus, 'pending');
    expect(
      (await f.db.getDump('fixture-private-local'))!.syncStatus,
      'local_only',
    );
  });
}
