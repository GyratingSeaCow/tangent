// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The in-screen running line must name the model that is actually decoding
// the recording, not "faster-whisper" — the engine, which stopped being the
// answer to "which model?" the moment the model became selectable.
//
// It reads the SettingsStore mirror rather than the network: this panel is on
// screen DURING a job, and a picker that cannot reach the server must still
// render instantly with the last model this device saw.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/models/pair_pending.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';

/// Never called: this test drives the panel from durable rows, so the client
/// only has to EXIST. Throwing keeps an unexpected call visible.
class _UnusedTranscriptionClient implements TranscriptionClient {
  @override
  String get baseUrl => 'http://test';

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
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async =>
      throw UnimplementedError();

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async =>
      throw UnimplementedError();

  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async =>
      throw UnimplementedError();

  @override
  Future<ServerInfo> getServerInfo() async => throw UnimplementedError();

  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) =>
      throw UnimplementedError();
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
  Future<Duration?> load(AudioLocator source) async =>
      const Duration(seconds: 4);
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  /// Pumps the detail screen over a RUNNING row with [mirror] as the model
  /// this device last saw the server using, and returns the running line.
  Future<String> runningLineFor(
    WidgetTester tester, {
    required String mirror,
    required String id,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final Directory temp =
        Directory.systemTemp.createTempSync('tangent-running-model-');
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    final AudioStorage storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final ServerTranscriptionService service = ServerTranscriptionService(
      client: _UnusedTranscriptionClient(),
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    final StreamController<DumpRow?> rows =
        StreamController<DumpRow?>.broadcast(sync: true);
    addTearDown(() async {
      await rows.close();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final DateTime now = DateTime.utc(2026, 9, 25);
    final DumpRow row = DumpRow(
      id: id,
      createdAt: now,
      updatedAt: now,
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Running model line',
      audioPath: storage.pathFor(id).path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'running',
      transcriptionRequestId: 'request-$id',
      transcriptionJobId: 'job-$id',
      transcriptionAttempt: 1,
      transcriptionStartedAt: now,
      transcriptionUpdatedAt: now,
    );
    await seedFileFixtureRow(db, row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          settingsStoreProvider
              .overrideWithValue(SettingsStore(whisperModel: mirror)),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider
              .overrideWith((ref) => _UnusedTranscriptionClient()),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          dumpByIdProvider(row.id).overrideWith((ref) => rows.stream),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: id,
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      rows.add(row);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Transcribing on your server'),
      findsOneWidget,
      reason: 'the running panel must be on screen for this assertion',
    );
    final Finder line = find.textContaining('The server is decoding audio');
    expect(line, findsOneWidget);
    return tester.widget<Text>(line).data!;
  }

  testWidgets('the running line names the mirrored model, not the engine',
      (tester) async {
    final String text =
        await runningLineFor(tester, mirror: 'large-v3', id: 'names-model');

    expect(
      text,
      contains('decoding audio with large-v3'),
      reason: 'the user picked a model; this line must say which one is on',
    );
    expect(
      text,
      isNot(contains('faster-whisper')),
      reason: 'faster-whisper is the engine, not the choice the user made',
    );
    // The rest of the line is unchanged: the panel still promises the work
    // survives leaving the screen, and still counts elapsed time.
    expect(text, contains('This continues if you leave this screen'));
    expect(text, contains('Elapsed'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a different mirrored model is named verbatim', (tester) async {
    final String text =
        await runningLineFor(tester, mirror: 'small', id: 'names-small');

    expect(text, contains('decoding audio with small'));
    expect(text, isNot(contains('large-v3')));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('an unknown model keeps the engine wording rather than a gap',
      (tester) async {
    // A device that has never reached the server has an empty mirror. Saying
    // "decoding audio with ." would read as a broken string; the honest
    // fallback is the engine name this screen shipped with.
    final String text =
        await runningLineFor(tester, mirror: '', id: 'unknown-model');

    expect(
      text,
      contains('decoding audio with faster-whisper'),
      reason: 'with no model known, the engine name is still true',
    );
    expect(text.toLowerCase(), isNot(contains('null')));
    expect(
      text,
      isNot(contains('with .')),
      reason: 'never render an empty model slot',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
