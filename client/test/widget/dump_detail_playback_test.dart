// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/scripted_storage_backend.dart' show ImmediateIo;
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/models/pair_pending.dart';
import '../support/resolved_temp.dart';

class _NoopTranscriptionClient implements TranscriptionClient {
  @override
  String get baseUrl => 'http://test';

  // Multi-device sync is not part of what this fake exercises. Throwing
  // rather than returning an empty result keeps an unexpected sync call
  // visible instead of silently passing.
  @override
  Future<List<int>> downloadAudio(String dumpId) async =>
      throw UnimplementedError();

  @override
  Future<List<PairPendingEntry>> pairPending() async =>
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

  @override
  Future<ServerInfo> getServerInfo() async => throw UnimplementedError();
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
    String filename = '',
    String mimeType = '',
  }) async {}
  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String? model,
  }) async =>
      TranscriptionJobSnapshot(
        id: 'job',
        requestId: requestId,
        dumpId: dumpId,
        status: 'queued',
        model: model ?? 'large-v3',
      );
  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async =>
      throw UnimplementedError();
  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {}
}

void main() {
  testWidgets('Dump detail plays, pauses, and seeks through its recording',
      (tester) async {
    final temp = createResolvedTempSync('tangent-playback-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db,
        backend: _PlaybackSourceBackend(), registerDrain: false,);
    final engine = _FakePlaybackEngine();
    final noopClient = _NoopTranscriptionClient();
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = DumpRow(
      id: 'playback-1',
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: 'brain_dump',
      durationSeconds: 20,
      title: 'Review me',
      audioPath: 'content://tangent/document/playback-1.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
    const location = (
      id: 'fixture-playback-root',
      label: 'Fixture SAF',
      directory: (
        kind: 'saf',
        path: '',
        treeUri: 'content://tangent/tree/root',
        authority: 'tangent',
        documentId: 'root'
      )
    );
    await db.into(db.dumps).insert(row);
    await db.customStatement(
        'INSERT INTO storage_locations(id,canonical_key,directory_json,label) VALUES(?,?,?,?)',
        [
          location.id,
          StorageCodec.canonicalKey(location.directory),
          StorageCodec.encodeDirectory(location.directory),
          location.label,
        ]);
    await db.bindRecording(
      (
        key: fileFixtureKey(row.id),
        location: location,
        audio: (kind: 'saf', value: row.audioPath),
        metadataName: '${row.id}.meta.json'
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => noopClient),
          serverTranscriptionServiceProvider.overrideWith(
            (ref) => ServerTranscriptionService(
              client: noopClient,
              db: db,
              recordingAccess: bound.access,
              mutations: bound.mutations,
            ),
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            () => engine,
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
            audioPath: row.audioPath,
            durationSeconds: row.durationSeconds,
          ),
        ),
      ),
    );
    await pumpBoundUntil(tester, () => engine.loadedSource != null);
    await tester.pumpAndSettle();

    expect(engine.loadedSource, (kind: 'saf', value: row.audioPath));
    expect(find.text('Recording playback'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('00:00 / 00:20'), findsOneWidget);

    await tester.tap(find.byTooltip('Play recording'));
    await tester.pump();
    expect(engine.playCount, 1);

    engine.emitPosition(const Duration(seconds: 7));
    await tester.pump();
    expect(find.text('00:07 / 00:20'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeEnd!(15);
    await tester.pump();
    expect(engine.lastSeek, const Duration(seconds: 15));

    await tester.tap(find.byTooltip('Pause recording'));
    await tester.pump();
    expect(engine.pauseCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

// Synthetic provider locator: the route must pass the backend's typed source
// unchanged, rather than guessing its kind from row.audioPath.
final class _PlaybackSourceBackend extends FilesystemStorageBackend {
  @override
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding) =>
      ImmediateIo('fixture-playback', Ok(binding.audio));
}

final class _FakePlaybackEngine implements RecordingPlaybackEngine {
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  AudioLocator? loadedSource;
  Duration? lastSeek;
  int playCount = 0;
  int pauseCount = 0;

  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Future<Duration?> load(AudioLocator source) async {
    loadedSource = source;
    return const Duration(seconds: 20);
  }

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _positions.add(position);
  }

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _completed.close();
  }

  void emitPosition(Duration value) => _positions.add(value);
}
