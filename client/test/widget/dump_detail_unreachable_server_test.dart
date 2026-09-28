// SPDX-License-Identifier: AGPL-3.0-or-later
// The silent spinner: a server transcription retrying an address that
// never answers (a Wi-Fi address on cellular) used to show "Uploading
// audio to your server" with a progress bar for as long as the user cared
// to watch. The panel must NAME the address and say what to change, while
// the retries keep going underneath.
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
import '../support/resolved_temp.dart';

/// Never called: this test drives the panel from durable rows, so the client
/// only has to EXIST. Throwing keeps an unexpected call visible.
class _UnusedTranscriptionClient implements TranscriptionClient {
  _UnusedTranscriptionClient({this.baseUrl = 'http://test'});

  @override
  final String baseUrl;

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
    String? model,
    bool translate = false,
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
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps the detail screen for a row that is UPLOADING with the
  /// service's `reconciliation_pending:` marker set — the persisted shape
  /// of "the server did not answer, retrying" — started [startedAgo]
  /// before now, with the client pointed at [baseUrl]. Returns the text
  /// of the unreachable notice, or null when none is rendered.
  Future<String?> noticeFor(
    WidgetTester tester, {
    required String id,
    required String baseUrl,
    required Duration startedAgo,
    String? marker = 'reconciliation_pending: DioException [connection timeout]',
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final Directory temp = createResolvedTempSync('tangent-unreachable-');
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

    final DateTime started = DateTime.now().subtract(startedAgo);
    final DumpRow row = DumpRow(
      id: id,
      createdAt: started,
      updatedAt: started,
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Cellular upload',
      audioPath: storage.pathFor(id).path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'uploading',
      transcriptionRequestId: 'request-$id',
      transcriptionAttempt: 1,
      transcriptionStartedAt: started,
      transcriptionUpdatedAt: started,
      transcriptionError: marker,
    );
    await seedFileFixtureRow(db, row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          settingsStoreProvider
              .overrideWithValue(SettingsStore(whisperModel: 'large-v3')),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith(
            (ref) => _UnusedTranscriptionClient(baseUrl: baseUrl),
          ),
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
      find.text('Uploading audio to your server'),
      findsOneWidget,
      reason: 'the uploading panel must be on screen for this assertion',
    );
    final Finder notice =
        find.byKey(const ValueKey<String>('unreachable-server-notice'));
    if (notice.evaluate().isEmpty) return null;
    return tester.widget<Text>(notice).data;
  }

  testWidgets(
      'a LAN address that has not answered for a minute is named on the panel',
      (tester) async {
    final String? text = await noticeFor(
      tester,
      id: 'lan-stuck',
      baseUrl: 'http://192.168.1.206:8765',
      startedAgo: const Duration(minutes: 1),
    );

    expect(text, isNotNull, reason: 'the silent spinner is the bug');
    expect(text, contains("Can't reach the server at 192.168.1.206:8765"));
    expect(
      text,
      contains('Tailscale address (http://100.x.x.x:8765)'),
      reason: 'the fix must be on the screen the user is staring at',
    );
    // The retries are still running: the panel keeps its progress bar.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a fresh attempt is not called unreachable yet',
      (tester) async {
    final String? text = await noticeFor(
      tester,
      id: 'lan-fresh',
      baseUrl: 'http://192.168.1.206:8765',
      startedAgo: const Duration(seconds: 10),
    );
    expect(text, isNull, reason: 'a slow link must not be shamed early');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('no retry marker means the server is simply working',
      (tester) async {
    final String? text = await noticeFor(
      tester,
      id: 'lan-working',
      baseUrl: 'http://192.168.1.206:8765',
      startedAgo: const Duration(minutes: 5),
      marker: null,
    );
    expect(text, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
