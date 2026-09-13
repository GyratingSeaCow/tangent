// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockClient extends Mock implements TranscriptionClient {}

class _MockConnectivity extends Mock implements ConnectivityService {}

void main() {
  setUpAll(() {
    registerFallbackValue(ConnectivityStatus.wifi);
  });

  group('SyncEngine', () {
    late Directory tmp;
    late LocalDb db;
    late _MockClient client;
    late _MockConnectivity conn;
    late SyncEngine engine;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_sync_');
      db = LocalDb.forTesting(NativeDatabase.memory());
      client = _MockClient();
      conn = _MockConnectivity();
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.wifi);
      when(() => conn.statusStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => client.baseUrl).thenReturn('http://test');
      engine = SyncEngine(
        db: db,
        audioStorage: AudioStorage.test(tmp),
        client: client,
        connectivity: conn,
        settings: SettingsStore(),
      );
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('syncNow with empty queue is a no-op', () async {
      await engine.syncNow();
      verifyNever(
        () => client.createDump(
          id: any(named: 'id'),
          mode: any(named: 'mode'),
          durationSeconds: any(named: 'durationSeconds'),
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      );
      expect(engine.isSyncing, isFalse);
    });

    test('syncNow skips when offline', () async {
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.offline);
      await engine.syncNow();
      verifyNever(
        () => client.createDump(
          id: any(named: 'id'),
          mode: any(named: 'mode'),
          durationSeconds: any(named: 'durationSeconds'),
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      );
    });

    test('syncNow uploads pending dumps and marks synced', () async {
      await db.upsertDump(DumpRow(
        id: 'test-dump',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'Test',
        audioPath: '${tmp.path}/audio/test-dump.opus',
        audioSizeBytes: 100,
        syncStatus: SyncStatus.pending.wireValue,
        syncAttempts: 0,
      ));
      await File('${tmp.path}/audio/test-dump.opus')
          .writeAsBytes(Uint8List(100));
      when(
        () => client.createDump(
          id: any(named: 'id'),
          mode: any(named: 'mode'),
          durationSeconds: any(named: 'durationSeconds'),
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      ).thenAnswer((_) async => 'test-dump');
      when(
        () => client.uploadAudio(
          dumpId: any(named: 'dumpId'),
          audioBytes: any(named: 'audioBytes'),
        ),
      ).thenAnswer((_) async {});
      when(() => client.enqueueTranscription(any()))
          .thenAnswer((_) async => 'job-1');

      await engine.syncNow();

      final fetched = await db.getDump('test-dump');
      expect(fetched!.syncStatus, SyncStatus.synced.wireValue);
      expect(engine.lastSync, isNotNull);
    });

    test('syncNow marks dump failed when audio file missing', () async {
      await db.upsertDump(DumpRow(
        id: 'orphan-dump',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'No audio',
        audioPath: '/nonexistent.opus',
        audioSizeBytes: 0,
        syncStatus: SyncStatus.pending.wireValue,
        syncAttempts: 0,
      ));
      await engine.syncNow();

      final fetched = await db.getDump('orphan-dump');
      expect(fetched!.syncStatus, SyncStatus.failed.wireValue);
      expect(fetched.syncAttempts, 1);
      expect(fetched.lastSyncError, contains('audio file missing'));
    });
  });
}