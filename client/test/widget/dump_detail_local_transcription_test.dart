// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';

import 'package:tangent/models/server_info.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/services/recording_playback.dart';

import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

class _FakeTranscriptionClient implements TranscriptionClient {
  _FakeTranscriptionClient({required this.completedTranscript});

  final String completedTranscript;

  @override
  String get baseUrl => 'http://test';

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
  }) async {}

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async =>
      TranscriptionJobSnapshot(
        id: 'job-$dumpId',
        requestId: requestId,
        dumpId: dumpId,
        status: 'queued',
        model: model,
      );

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
    yield JobEvent('queued', const {});
    yield JobEvent('running', const {});
    yield JobEvent('completed', {'transcript': completedTranscript});
  }
}

void main() {
  testWidgets('Transcribe uploads to the server and persists the transcript',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-detail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final fake = _FakeTranscriptionClient(completedTranscript: 'server side');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      audioStorage: storage,
    );
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = DumpRow(
      id: 'remote-1',
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 13),
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Remote recording',
      audioPath: storage.pathFor('remote-1').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
    await db.upsertDump(row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => fake),
          serverTranscriptionServiceProvider.overrideWith(
            (ref) => service,
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'remote-1',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final transcribeButton = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.runAsync(() async {
      transcribeButton.onPressed!();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await db.getDump(row.id))?.transcript != 'server side') {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for the server transcript to persist');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('server side'), findsOneWidget);
    final saved = await db.getDump(row.id);
    expect(saved!.transcript, 'server side');
    expect(saved.syncStatus, 'pending');
  });

  testWidgets('Meeting detail prioritizes notes and expands raw transcript',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-detail-meeting-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      audioStorage: storage,
    );
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    await db.upsertDump(
      DumpRow(
        id: 'meeting-detail',
        createdAt: DateTime.utc(2026, 9, 14),
        updatedAt: DateTime.utc(2026, 9, 14),
        mode: 'meeting',
        durationSeconds: 4,
        title: 'Launch meeting',
        transcript: 'Exact raw transcript words.',
        meetingNotes: '# Launch\n\n## Summary\n\nQuoted summary.',
        audioPath: storage.pathFor('meeting-detail').path,
        audioSizeBytes: 3,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      ),
    );
    storage.pathFor('meeting-detail').writeAsBytesSync([1, 2, 3]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => fake),
          serverTranscriptionServiceProvider.overrideWith(
            (ref) => service,
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'meeting-detail',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Meeting Notes'), findsOneWidget);
    expect(find.textContaining('Quoted summary.'), findsOneWidget);
    expect(find.text('Exact raw transcript words.'), findsNothing);

    await tester.tap(find.widgetWithText(ExpansionTile, 'Raw Transcript'));
    await tester.pumpAndSettle();
    expect(find.text('Exact raw transcript words.'), findsOneWidget);
  });
}

final class _TestPlaybackEngine implements RecordingPlaybackEngine {
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Future<Duration?> load(String source) async => const Duration(seconds: 4);
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}
