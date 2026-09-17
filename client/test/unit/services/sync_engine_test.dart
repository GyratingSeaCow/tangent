// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import '../../support/bound_row_fixture.dart';
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
    late DefaultRecordingMutationCoordinator mutations;
    late FilesystemStorageBackend backend;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_sync_');
      db = LocalDb.forTesting(NativeDatabase.memory());
      await Directory('${tmp.path}/Tangent').create();
      backend = FilesystemStorageBackend();
      mutations = DefaultRecordingMutationCoordinator(db: db);
      await mutations.restoreFences(unsettled: await backend.unsettledUses());
      client = _MockClient();
      conn = _MockConnectivity();
      when(() => conn.currentStatus())
          .thenAnswer((_) async => ConnectivityStatus.wifi);
      when(() => conn.statusStream).thenAnswer((_) => const Stream.empty());
      when(() => client.baseUrl).thenReturn('http://test');
      engine = SyncEngine(
        db: db,
        recordingAccess: BoundRecordingAccess(
          db: db,
          backend: backend,
          mutations: mutations,
        ),
        mutations: mutations,
        client: client,
        connectivity: conn,
        settings: SettingsStore(),
      );
    });

    tearDown(() async {
      engine.dispose();
      await backend.drain();
      await mutations.drain();
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
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'test-dump',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'Test',
          audioPath: '${tmp.path}/Tangent/test-dump.opus',
          audioSizeBytes: 100,
          syncStatus: SyncStatus.pending.wireValue,
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      await File('${tmp.path}/Tangent/test-dump.opus')
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
      await engine.syncNow();

      final fetched = await db.getDump('test-dump');
      expect(fetched!.syncStatus, SyncStatus.synced.wireValue);
      expect(engine.lastSync, isNotNull);
      verify(
        () => client.createDump(
          id: 'test-dump',
          mode: 'brain_dump',
          durationSeconds: any(named: 'durationSeconds'),
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      ).called(1);
      verify(
        () => client.uploadAudio(
          dumpId: 'test-dump',
          audioBytes: any(named: 'audioBytes'),
        ),
      ).called(1);
      verifyNever(
        () => client.enqueueTranscription(
          any(),
          requestId: any(named: 'requestId'),
        ),
      );
    });

    test('text_note rows sync metadata only — no audio transport', () async {
      const body = 'typed note body';
      final noteBytes = utf8.encode(body);
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'note-dump',
          createdAt: DateTime.utc(2026, 1, 2),
          updatedAt: DateTime.utc(2026, 1, 2),
          mode: 'text_note',
          durationSeconds: 0,
          title: 'Note 2026-01-02 00-00-00',
          transcript: body,
          audioPath: '${tmp.path}/Tangent/note-dump.md',
          audioSizeBytes: noteBytes.length,
          syncStatus: SyncStatus.pending.wireValue,
          syncAttempts: 0,
          transcriptionStatus: 'not_applicable',
          transcriptionAttempt: 0,
        ),
      );
      await File('${tmp.path}/Tangent/note-dump.md').writeAsBytes(noteBytes);
      when(
        () => client.createDump(
          id: any(named: 'id'),
          mode: any(named: 'mode'),
          durationSeconds: any(named: 'durationSeconds'),
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      ).thenAnswer((_) async => 'note-dump');

      await engine.syncNow();

      expect(
        (await db.getDump('note-dump'))!.syncStatus,
        SyncStatus.synced.wireValue,
      );
      verify(
        () => client.createDump(
          id: 'note-dump',
          mode: 'text_note',
          durationSeconds: 0,
          title: any(named: 'title'),
          createdAt: any(named: 'createdAt'),
        ),
      ).called(1);
      verifyNever(
        () => client.uploadAudio(
          dumpId: any(named: 'dumpId'),
          audioBytes: any(named: 'audioBytes'),
        ),
      );
    });

    test('syncNow marks dump failed when audio file missing', () async {
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'orphan-dump',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'No audio',
          audioPath: '${tmp.path}/Tangent/orphan-dump.opus',
          audioSizeBytes: 0,
          syncStatus: SyncStatus.pending.wireValue,
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      await engine.syncNow();

      final fetched = await db.getDump('orphan-dump');
      expect(fetched!.syncStatus, SyncStatus.failed.wireValue);
      expect(fetched.syncAttempts, 1);
      expect(fetched.lastSyncError, contains('audio file missing'));
    });

    test('meeting audio and transcript never leave the device', () async {
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'private-meeting',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          mode: 'meeting',
          durationSeconds: 5,
          title: 'Private meeting',
          transcript: 'Confidential meeting words',
          meetingNotes: '# Private meeting',
          audioPath: '${tmp.path}/Tangent/private-meeting.opus',
          audioSizeBytes: 3,
          syncStatus: SyncStatus.localOnly.wireValue,
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      await File('${tmp.path}/Tangent/private-meeting.opus')
          .writeAsBytes([1, 2, 3]);

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
      verifyNever(
        () => client.uploadAudio(
          dumpId: any(named: 'dumpId'),
          audioBytes: any(named: 'audioBytes'),
        ),
      );
      // `local_only` meetings are filtered out by `dumpsNeedingUpload`, so
      // their status is unchanged after sync.
      expect(
        (await db.getDump('private-meeting'))!.syncStatus,
        SyncStatus.localOnly.wireValue,
      );
    });
  });
}
