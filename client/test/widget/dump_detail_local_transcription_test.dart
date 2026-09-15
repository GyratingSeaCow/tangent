// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';

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

final class _PausingMeetingNotesDb extends LocalDb {
  _PausingMeetingNotesDb() : super.forTesting(NativeDatabase.memory());

  Completer<void>? _pausedUpdate;
  Completer<void>? _releaseUpdate;
  Completer<void>? _meetingNotesUpdateFinished;
  bool _pauseNextUpdate = false;

  void pauseNextMeetingNotesUpdate() {
    _pausedUpdate = Completer<void>();
    _releaseUpdate = Completer<void>();
    _meetingNotesUpdateFinished = Completer<void>();
    _pauseNextUpdate = true;
  }

  Future<void> get pausedUpdate => _pausedUpdate!.future;

  Future<void> get meetingNotesUpdateFinished =>
      _meetingNotesUpdateFinished!.future;

  void releasePausedUpdate() => _releaseUpdate!.complete();

  @override
  Future<DumpRow> updateDumpMeetingNotes(
    String id, {
    required String expectedTitle,
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String meetingNotes,
    required DateTime now,
  }) async {
    if (_pauseNextUpdate) {
      _pauseNextUpdate = false;
      _pausedUpdate!.complete();
      await _releaseUpdate!.future;
    }
    try {
      return await super.updateDumpMeetingNotes(
        id,
        expectedTitle: expectedTitle,
        expectedTranscript: expectedTranscript,
        expectedTranscriptionAttempt: expectedTranscriptionAttempt,
        expectedTranscriptionRequestId: expectedTranscriptionRequestId,
        meetingNotes: meetingNotes,
        now: now,
      );
    } finally {
      if (!_meetingNotesUpdateFinished!.isCompleted) {
        _meetingNotesUpdateFinished!.complete();
      }
    }
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
          dumpByIdProvider(row.id).overrideWith(
            (ref) => Stream<DumpRow?>.value(row),
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
      while (true) {
        final current = await db.getDump(row.id);
        if (current?.transcript == 'server side' &&
            current?.transcriptionError == null) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for transcript and sidecar finalization');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    final saved = await db.getDump(row.id);
    expect(saved!.transcript, 'server side');
    expect(saved.syncStatus, 'pending');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('Detail redraws from durable running and completed rows',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp =
        Directory.systemTemp.createTempSync('tangent-detail-reactive-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      audioStorage: storage,
    );
    final rows = StreamController<DumpRow?>.broadcast(sync: true);
    addTearDown(() async {
      await rows.close();
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final now = DateTime.utc(2026, 9, 14);
    final row = DumpRow(
      id: 'reactive-detail',
      createdAt: now,
      updatedAt: now,
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Reactive detail',
      audioPath: storage.pathFor('reactive-detail').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
    await db.upsertDump(row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => fake),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          dumpByIdProvider(row.id).overrideWith((ref) => rows.stream),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'reactive-detail',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(rows.hasListener, isTrue);
    Future<void> emitRow(DumpRow next) async {
      await tester.runAsync(() async {
        rows.add(next);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }

    await emitRow(row);
    expect(find.text('Transcribe'), findsOneWidget);

    await emitRow(
      row.copyWith(
        updatedAt: now.add(const Duration(seconds: 1)),
        transcriptionStatus: 'running',
        transcriptionRequestId: const Value('request-reactive'),
        transcriptionJobId: const Value('job-reactive'),
        transcriptionAttempt: 1,
        transcriptionStartedAt: Value(now),
        transcriptionUpdatedAt: Value(now.add(const Duration(seconds: 1))),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Transcribing on server'), findsOneWidget);
    expect(find.text('Transcribing on your server'), findsOneWidget);

    await emitRow(
      row.copyWith(
        updatedAt: now.add(const Duration(seconds: 2)),
        transcript: const Value('Reactive transcript'),
        transcriptionStatus: 'completed',
        transcriptionRequestId: const Value('request-reactive'),
        transcriptionJobId: const Value('job-reactive'),
        transcriptionAttempt: 1,
        transcriptionStartedAt: Value(now),
        transcriptionUpdatedAt: Value(now.add(const Duration(seconds: 2))),
        transcriptionCompletedAt: Value(now.add(const Duration(seconds: 2))),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Reactive transcript'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
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
    final row = DumpRow(
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
      transcriptionStatus: 'completed',
      transcriptionRequestId: 'request-meeting-detail',
      transcriptionJobId: 'job-meeting-detail',
      transcriptionAttempt: 2,
      transcriptionStartedAt: DateTime.utc(2026, 9, 14, 0, 0, 1),
      transcriptionUpdatedAt: DateTime.utc(2026, 9, 14, 0, 0, 2),
      transcriptionCompletedAt: DateTime.utc(2026, 9, 14, 0, 0, 2),
    );
    await db.upsertDump(row);
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
          dumpByIdProvider('meeting-detail').overrideWith(
            (ref) => Stream<DumpRow?>.value(row),
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

    await tester.enterText(find.byType(TextField), 'Renamed launch meeting');
    final saveButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (true) {
        final sidecar = storage.metaPathFor('meeting-detail');
        if (await sidecar.exists()) {
          final metadata =
              jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
          if (metadata['title'] == 'Renamed launch meeting') break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('title sidecar did not finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);

    final notesButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('regenerate-notes-meeting-detail')),
    );
    await tester.runAsync(() async {
      notesButton.onPressed!();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (true) {
        final sidecar = storage.metaPathFor('meeting-detail');
        if (await sidecar.exists()) {
          final metadata =
              jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
          if (metadata['meetingNotes'] !=
              '# Launch\n\n## Summary\n\nQuoted summary.') {
            break;
          }
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('meeting-notes sidecar did not finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    });
    await tester.pump();
    expect(find.text('Meeting notes updated'), findsOneWidget);

    final saved = (await db.getDump('meeting-detail'))!;
    expect(saved.title, 'Renamed launch meeting');
    expect(saved.transcript, 'Exact raw transcript words.');
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcriptionRequestId, 'request-meeting-detail');
    expect(saved.transcriptionJobId, 'job-meeting-detail');
    expect(saved.transcriptionAttempt, 2);
    final metadata = jsonDecode(
      storage.metaPathFor('meeting-detail').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(metadata['title'], 'Renamed launch meeting');
    expect(metadata['transcript'], 'Exact raw transcript words.');
    expect(metadata['transcriptionStatus'], 'completed');
    expect(metadata['transcriptionRequestId'], 'request-meeting-detail');
    expect(metadata['transcriptionJobId'], 'job-meeting-detail');
    expect(metadata['transcriptionAttempt'], 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'paused old note regeneration cannot overwrite an identical-transcript retry or sidecar',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-notes-aba-race-');
    final db = _PausingMeetingNotesDb();
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
    final now = DateTime.utc(2026, 9, 14, 20);
    final original = DumpRow(
      id: 'notes-aba-race',
      createdAt: now,
      updatedAt: now,
      mode: 'meeting',
      durationSeconds: 4,
      title: 'Same meeting title',
      transcript: 'The transcript is intentionally identical.',
      meetingNotes: 'attempt one notes',
      audioPath: storage.pathFor('notes-aba-race').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionRequestId: 'request-attempt-1',
      transcriptionJobId: 'job-attempt-1',
      transcriptionAttempt: 1,
      transcriptionStartedAt: now,
      transcriptionUpdatedAt: now,
      transcriptionCompletedAt: now,
    );
    await db.upsertDump(original);
    storage.pathFor(original.id).writeAsBytesSync([1, 2, 3]);
    storage
        .metaPathFor(original.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(original)));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => fake),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          dumpByIdProvider(original.id).overrideWith(
            (ref) => Stream<DumpRow?>.value(original),
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'notes-aba-race',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final notesButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('regenerate-notes-notes-aba-race')),
    );
    late DumpRow saved;
    late Map<String, dynamic> sidecar;

    await tester.runAsync(() async {
      db.pauseNextMeetingNotesUpdate();
      notesButton.onPressed!();
      await db.pausedUpdate.timeout(const Duration(seconds: 2));

      final newerAttempt = await db.beginTranscriptionAttempt(
        original.id,
        requestId: 'request-attempt-2',
        now: now.add(const Duration(minutes: 1)),
      );
      final completed = await db.completeTranscriptionAttempt(
        original.id,
        attempt: newerAttempt.transcriptionAttempt,
        requestId: newerAttempt.transcriptionRequestId!,
        transcript: original.transcript!,
        meetingNotes: 'attempt two notes',
        now: now.add(const Duration(minutes: 2)),
      );
      expect(completed, isTrue);
      final newer = (await db.getDump(original.id))!;
      await storage.writeMetadata(original.id, dumpMetadata(newer));

      db.releasePausedUpdate();
      await db.meetingNotesUpdateFinished.timeout(const Duration(seconds: 2));

      final afterUpdate = (await db.getDump(original.id))!;
      if (afterUpdate.meetingNotes != 'attempt two notes') {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (true) {
          final metadata = jsonDecode(
            await storage.metaPathFor(original.id).readAsString(),
          ) as Map<String, dynamic>;
          if (metadata['meetingNotes'] != 'attempt two notes') break;
          if (DateTime.now().isAfter(deadline)) {
            fail('stale meeting-notes sidecar write did not finish');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      saved = (await db.getDump(original.id))!;
      sidecar = jsonDecode(
        await storage.metaPathFor(original.id).readAsString(),
      ) as Map<String, dynamic>;
    });
    expect(saved.transcriptionAttempt, 2);
    expect(saved.transcriptionRequestId, 'request-attempt-2');
    expect(saved.title, 'Same meeting title');
    expect(saved.transcript, original.transcript);
    expect(saved.meetingNotes, 'attempt two notes');
    expect(sidecar['transcriptionAttempt'], 2);
    expect(sidecar['transcriptionRequestId'], 'request-attempt-2');
    expect(sidecar['title'], 'Same meeting title');
    expect(sidecar['transcript'], original.transcript);
    expect(sidecar['meetingNotes'], 'attempt two notes');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
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
