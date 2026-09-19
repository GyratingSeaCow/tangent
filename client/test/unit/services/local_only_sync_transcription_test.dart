// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Jeff's requirement, split into its two independent network behaviours:
//
//   (a) Recordings are NOT backed up to the server. Bulk upload stays off.
//   (b) Transcription to his own self-hosted server over Tailscale DOES run,
//       specifically while the phone is on mobile data.
//
// These tests hold both halves against the same seeded recording so a change
// that satisfies one by breaking the other cannot pass.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/sync_engine.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/transcription_client.dart';
import '../../support/bound_row_fixture.dart';

class _MockConnectivity extends Mock implements ConnectivityService {}

/// Records every transport the app performs so a test can tell a *backup*
/// upload (driven by SyncEngine) apart from a *transcription* upload (driven
/// by ServerTranscriptionService reaching the self-hosted server).
class _RecordingClient implements TranscriptionClient {
  final List<String> calls = [];

  // Multi-device sync is not part of what this fake exercises. Throwing
  // rather than returning an empty result keeps an unexpected sync call
  // visible instead of silently passing.
  @override
  Future<List<int>> downloadAudio(String dumpId) async =>
      throw UnimplementedError();

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SyncPullPage> pullChanges({
    required String deviceId,
    required int sinceSeq,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async =>
      throw UnimplementedError();

  final List<List<int>> uploadedAudioBytes = [];

  @override
  String get baseUrl => 'http://tailscale-host:8765';

  @override
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async {
    calls.add('create');
    return id;
  }

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    calls.add('upload');
    uploadedAudioBytes.add(List<int>.from(audioBytes));
  }

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async {
    calls.add('enqueue');
    return TranscriptionJobSnapshot(
      id: 'job-$dumpId',
      requestId: requestId,
      dumpId: dumpId,
      status: 'queued',
      model: model,
    );
  }

  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async =>
      throw UnimplementedError();

  @override
  Future<ServerInfo> getServerInfo() async => throw UnimplementedError();

  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {
    calls.add('stream');
    yield const JobEvent('queued', {});
    yield const JobEvent('running', {});
    yield const JobEvent('completed', {'transcript': 'transcribed on cellular'});
  }
}

void main() {
  setUpAll(() => registerFallbackValue(ConnectivityStatus.mobile));

  late Directory tmp;
  late LocalDb db;
  late FilesystemStorageBackend backend;
  late DefaultRecordingMutationCoordinator mutations;
  late RecordingAccess access;
  late _RecordingClient client;
  late _MockConnectivity conn;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangent_localonly_');
    await Directory('${tmp.path}/Tangent').create();
    db = LocalDb.forTesting(NativeDatabase.memory());
    backend = FilesystemStorageBackend();
    mutations = DefaultRecordingMutationCoordinator(db: db);
    await mutations.restoreFences(unsettled: await backend.unsettledUses());
    access = BoundRecordingAccess(db: db, backend: backend, mutations: mutations);
    client = _RecordingClient();
    conn = _MockConnectivity();
    when(() => conn.statusStream).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await backend.drain();
    await mutations.drain();
    await db.close();
    await tmp.delete(recursive: true);
  });

  SyncEngine engineWith(SettingsStore settings) {
    final engine = SyncEngine(
      db: db,
      recordingAccess: access,
      mutations: mutations,
      client: client,
      connectivity: conn,
      settings: settings,
    );
    addTearDown(engine.dispose);
    return engine;
  }

  Future<void> seed(String id) async {
    await seedFileFixtureRow(
      db,
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 17),
        updatedAt: DateTime.utc(2026, 9, 17),
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'Row $id',
        audioPath: '${tmp.path}/Tangent/$id.opus',
        audioSizeBytes: 100,
        syncStatus: SyncStatus.pending.wireValue,
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      ),
    );
    await File('${tmp.path}/Tangent/$id.opus').writeAsBytes(Uint8List(100));
  }

  group('recordings stay on the device', () {
    test('device-only storage blocks bulk upload on Wi-Fi', () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.wifi);
      await seed('local-1');

      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: true, wifiOnlySync: false),
      ).syncNow();

      expect(client.calls, isEmpty,
          reason: 'a recording must never be uploaded for backup',);
      expect((await db.getDump('local-1'))!.syncStatus,
          SyncStatus.pending.wireValue,);
    });

    test('device-only storage blocks bulk upload on cellular', () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.mobile);
      await seed('local-2');

      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: true, wifiOnlySync: false),
      ).syncNow();

      expect(client.calls, isEmpty);
      expect((await db.getDump('local-2'))!.syncStatus,
          SyncStatus.pending.wireValue,);
    });

    test('opting into backup still honours the Wi-Fi-only upload window',
        () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.mobile);
      await seed('local-3');

      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: false, wifiOnlySync: true),
      ).syncNow();

      expect(client.calls, isEmpty, reason: 'cellular is outside the window');
    });

    test('opting into backup uploads on Wi-Fi as before', () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.wifi);
      await seed('local-4');

      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: false, wifiOnlySync: true),
      ).syncNow();

      expect(client.calls, ['create', 'upload']);
      expect((await db.getDump('local-4'))!.syncStatus,
          SyncStatus.synced.wireValue,);
    });

    test('device-only storage does not weaken meeting/local_only privacy',
        () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.wifi);
      await seed('private-meeting');
      await db.customStatement(
        "UPDATE dumps SET mode='meeting' WHERE id=?",
        ['private-meeting'],
      );

      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: false, wifiOnlySync: false),
      ).syncNow();

      expect(client.calls, isEmpty);
    });
  });

  group('transcription reaches the self-hosted server on mobile data', () {
    test('transcribes while connectivity reports cellular and storage is '
        'device-only', () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.mobile);
      await seed('cell-1');

      // Bulk upload must stay off for this very row...
      await engineWith(
        SettingsStore(keepRecordingsOnDeviceOnly: true, wifiOnlySync: true),
      ).syncNow();
      expect(client.calls, isEmpty);

      // ...while transcription to Jeff's own server still runs over cellular.
      final service = ServerTranscriptionService(
        client: client,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-cell-1',
        now: () => DateTime.utc(2026, 9, 17, 12),
      );
      addTearDown(service.dispose);

      await service.transcribeDump('cell-1');

      final row = (await db.getDump('cell-1'))!;
      expect(row.transcriptionStatus, 'completed');
      expect(row.transcript, 'transcribed on cellular');
      expect(client.calls, ['create', 'upload', 'enqueue', 'stream'],
          reason: 'transcription sends the audio it needs to transcribe',);
      expect(client.uploadedAudioBytes, hasLength(1));
      // The transcription upload is not a backup: the row is still not synced.
      expect(row.syncStatus, SyncStatus.pending.wireValue);
    });

    test('transcription is not gated by the Wi-Fi-only upload setting',
        () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.mobile);
      await seed('cell-2');

      final service = ServerTranscriptionService(
        client: client,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-cell-2',
        now: () => DateTime.utc(2026, 9, 17, 12),
      );
      addTearDown(service.dispose);

      await service.transcribeDump('cell-2');

      expect((await db.getDump('cell-2'))!.transcriptionStatus, 'completed');
      expect(client.calls, contains('enqueue'));
    });
  });
}
