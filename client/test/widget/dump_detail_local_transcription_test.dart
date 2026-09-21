// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/storage_contract.dart';
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

import 'manual_transcript_publication_cases.dart'
    show manualTranscriptPublicationTests;

class _FakeTranscriptionClient implements TranscriptionClient {
  _FakeTranscriptionClient({
    required this.completedTranscript,
    this.pauseBeforeTerminal = false,
    this.failure,
  });

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

  final String completedTranscript;
  final bool pauseBeforeTerminal;
  final String? failure;
  int createCalls = 0;
  int uploadCalls = 0;
  int enqueueCalls = 0;
  final List<String> requestIds = [];
  Completer<void>? _terminalGate;

  bool get isWaitingBeforeTerminal => _terminalGate != null;

  void releaseTerminal() {
    final gate = _terminalGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  String get baseUrl => 'http://test';

  @override
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async {
    createCalls++;
    return id;
  }

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    uploadCalls++;
  }

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async {
    enqueueCalls++;
    requestIds.add(requestId);
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
    yield JobEvent('queued', const {});
    yield JobEvent('running', const {});
    if (pauseBeforeTerminal) {
      final gate = Completer<void>();
      _terminalGate = gate;
      await gate.future;
    }
    if (failure != null) {
      yield JobEvent('failed', {'error': failure!});
    } else {
      yield JobEvent('completed', {'transcript': completedTranscript});
    }
  }
}

final class _PausedTranscriptReturnDb extends LocalDb {
  _PausedTranscriptReturnDb() : super.forTesting(NativeDatabase.memory());
  bool pauseReturn = false;
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DumpRow> updateDumpTranscript(
    String id, {
    required RecordingKey storageKey,
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String transcript,
    required DateTime now,
  }) async {
    final saved = await super.updateDumpTranscript(
      id,
      storageKey: storageKey,
      expectedTranscript: expectedTranscript,
      expectedTranscriptionAttempt: expectedTranscriptionAttempt,
      expectedTranscriptionRequestId: expectedTranscriptionRequestId,
      transcript: transcript,
      now: now,
    );
    committed.complete();
    if (pauseReturn) await release.future;
    return saved;
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
    required RecordingKey storageKey,
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
        storageKey: storageKey,
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
  manualTranscriptPublicationTests();
  testWidgets('Transcribe uploads to the server and persists the transcript',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-detail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'server side');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
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
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
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
    await pumpBoundUntil(
      tester,
      () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
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
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    final rows = StreamController<DumpRow?>.broadcast(sync: true);
    addTearDown(() async {
      await rows.close();
      await disposeBoundWidget(tester, bound);
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
    await seedFileFixtureRow(db, row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
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
    await pumpBoundUntil(
        tester, () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,);
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
    expect(find.text('Transcribe again'), findsOneWidget);
  });

  testWidgets(
      'existing transcript requires confirmation and stays visible until replacement succeeds',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-overwrite-ok-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'Replacement transcript',
      pauseBeforeTerminal: true,
    );
    var requestAllocations = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
      requestIdFactory: () {
        requestAllocations++;
        return 'request-replacement';
      },
    );
    addTearDown(() async {
      fake.releaseTerminal();
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final row = _completedRow(
      storage,
      id: 'overwrite-ok',
      transcript: 'Original transcript',
      attempt: 4,
      requestId: 'request-original',
      jobId: 'job-original',
    );
    await seedFileFixtureRow(db, row);
    final rawAudio = <int>[8, 6, 7, 5, 3, 0, 9];
    storage.pathFor(row.id).writeAsBytesSync(rawAudio);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);
    expect(_editorText(tester, row.id), 'Original transcript');

    await tester.tap(find.byKey(ValueKey('transcribe-${row.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    late DumpRow cancelled;
    await tester.runAsync(() async {
      cancelled = (await db.getDump(row.id))!;
    });
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.enqueueCalls, 0);
    expect(cancelled.transcriptionAttempt, 4);
    expect(cancelled.transcriptionRequestId, 'request-original');
    expect(requestAllocations, 0);

    await tester.tap(find.byKey(ValueKey('transcribe-${row.id}')));
    await tester.pumpAndSettle();
    final overwriteButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Overwrite'),
    );
    late DumpRow running;
    late DumpRow completed;
    late Map<String, dynamic> sidecar;
    await tester.runAsync(() async {
      overwriteButton.onPressed!();
      final operationDone = service.transcribeDump(row.id);
      await _waitForRealCondition(
        () async => fake.isWaitingBeforeTerminal,
        description: 'server stream to pause before its terminal event',
      );
      running = await _waitForRow(
        db,
        row.id,
        (value) => value.transcriptionStatus == 'running',
      );
      fake.releaseTerminal();
      await operationDone;
      completed = (await db.getDump(row.id))!;
      sidecar = await _waitForMetadata(
        storage,
        row.id,
        (metadata) => metadata['transcript'] == 'Replacement transcript',
      );
    });

    expect(running.transcriptionAttempt, 5);
    expect(running.transcriptionRequestId, 'request-replacement');
    expect(running.transcriptionRequestId, isNot('request-original'));
    expect(running.transcript, 'Original transcript');
    expect(_editorText(tester, row.id), 'Original transcript');
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
    expect(fake.requestIds, ['request-replacement']);

    expect(completed.transcriptionAttempt, 5);
    expect(completed.transcript, 'Replacement transcript');
    expect(sidecar['transcriptionRequestId'], 'request-replacement');
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);

    await _disposeDetail(tester);
    await _mountDetail(tester, db, storage, fake, service, bound, completed);
    expect(_editorText(tester, row.id), 'Replacement transcript');
    await _disposeDetail(tester);
  });

  testWidgets('failed replacement preserves prior transcript and raw audio',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-overwrite-fail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      failure: 'replacement failed',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
      requestIdFactory: () => 'request-failure',
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final row = _completedRow(
      storage,
      id: 'overwrite-fail',
      transcript: 'Transcript that must survive',
      attempt: 2,
      requestId: 'request-before-failure',
      jobId: 'job-before-failure',
    );
    await seedFileFixtureRow(db, row);
    final rawAudio = <int>[1, 4, 1, 4, 2, 1];
    storage.pathFor(row.id).writeAsBytesSync(rawAudio);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);
    await tester.tap(find.byKey(ValueKey('transcribe-${row.id}')));
    await tester.pumpAndSettle();
    final overwriteButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Overwrite'),
    );
    late DumpRow failed;
    late Map<String, dynamic> sidecar;
    await tester.runAsync(() async {
      overwriteButton.onPressed!();
      await service.transcribeDump(row.id);
      failed = (await db.getDump(row.id))!;
      sidecar = jsonDecode(await storage.metaPathFor(row.id).readAsString())
          as Map<String, dynamic>;
    });

    expect(failed.transcriptionAttempt, 3);
    expect(failed.transcriptionRequestId, 'request-failure');
    expect(failed.transcript, 'Transcript that must survive');
    expect(_editorText(tester, row.id), 'Transcript that must survive');
    expect(sidecar['transcript'], 'Transcript that must survive');
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);

    await _disposeDetail(tester);
  });

  testWidgets(
      'editable multiline transcript blocks blank and saves SQLite plus sidecar without changing notes or audio',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-edit-save-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final row = _completedRow(
      storage,
      id: 'edit-save',
      mode: 'meeting',
      transcript: 'Original meeting transcript',
      meetingNotes: 'Notes must remain unchanged',
      attempt: 6,
      requestId: 'request-edit-save',
      jobId: 'job-edit-save',
    );
    await seedFileFixtureRow(db, row);
    final rawAudio = <int>[2, 7, 1, 8, 2, 8];
    storage.pathFor(row.id).writeAsBytesSync(rawAudio);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);
    // Option B: meeting transcripts start collapsed — expand before editing.
    await tester.tap(find.byKey(ValueKey('transcript-header-${row.id}')));
    await tester.pump();
    final editorFinder = find.byKey(ValueKey('transcript-editor-${row.id}'));
    final editor = tester.widget<TextField>(editorFinder);
    expect(editor.maxLines, isNull);
    expect(editor.keyboardType, TextInputType.multiline);
    expect(editor.controller!.text, 'Original meeting transcript');

    await tester.enterText(editorFinder, '   \n');
    await tester.pump();
    expect(find.text('Transcript cannot be blank'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(ValueKey('save-transcript-${row.id}')),
          )
          .onPressed,
      isNull,
    );

    const corrected = 'Corrected line one.\nCorrected line two.';
    await tester.enterText(editorFinder, corrected);
    await tester.pump();
    final saveFinder = find.byKey(ValueKey('save-transcript-${row.id}'));
    final saveButton = tester.widget<FilledButton>(saveFinder);
    expect(saveButton.onPressed, isNotNull);
    late DumpRow saved;
    late Map<String, dynamic> sidecar;
    await tester.runAsync(() async {
      saveButton.onPressed!();
      saved = await _waitForRow(
        db,
        row.id,
        (value) => value.transcript == corrected,
      );
      sidecar = await _waitForMetadata(
        storage,
        row.id,
        (metadata) => metadata['transcript'] == corrected,
      );
    });
    await tester.pump();

    expect(saved.meetingNotes, 'Notes must remain unchanged');
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcriptionAttempt, 6);
    expect(saved.transcriptionRequestId, 'request-edit-save');
    expect(saved.transcriptionJobId, 'job-edit-save');
    expect(sidecar['meetingNotes'], 'Notes must remain unchanged');
    expect(sidecar['transcriptionAttempt'], 6);
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);
    expect(find.text('Transcript saved'), findsOneWidget);

    await _disposeDetail(tester);
    await _mountDetail(tester, db, storage, fake, service, bound, saved);
    // Fresh mount resets Option B's collapsed state — expand to verify.
    await tester.tap(find.byKey(ValueKey('transcript-header-${row.id}')));
    await tester.pump();
    expect(_editorText(tester, row.id), corrected);
    expect(
      tester.widget<FilledButton>(saveFinder).onPressed,
      isNull,
    );
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);

    await _disposeDetail(tester);
  });

  testWidgets('fix round FIFO wait is presented from the live durable row',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('fifo-ui-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'Result',
      pauseBeforeTerminal: true,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      fake.releaseTerminal();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final second = _completedRow(
      storage,
      id: 'fifo-ui-second',
      transcript: 'Retained transcript',
      attempt: 1,
      requestId: 'old-request',
      jobId: 'old-job',
    );
    final first = second.copyWith(
        id: 'fifo-ui-first', audioPath: storage.pathFor('fifo-ui-first').path,);
    await tester.runAsync(() async {
      for (final row in [first, second]) {
        await seedFileFixtureRow(db, row);
        await storage.pathFor(row.id).writeAsBytes([1, 2, 3]);
      }
      unawaited(service.transcribeDump(first.id));
    });
    await _pumpRealUntil(tester, () => fake.isWaitingBeforeTerminal);
    await _mountDetail(
      tester,
      db,
      storage,
      fake,
      service,
      bound,
      second,
      live: true,
    );
    await tester.runAsync(() async {
      unawaited(service.transcribeDump(second.id));
    });
    await _pumpRealUntil(
      tester,
      () => find.text('Uploading…').evaluate().isNotEmpty,
    );
    expect(_editorText(tester, second.id), 'Retained transcript');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(ValueKey('transcribe-${second.id}')),
          )
          .onPressed,
      isNull,
    );
    expect(fake.createCalls, 1);
    expect(fake.enqueueCalls, 1);
    service.dispose();
    fake.releaseTerminal();
    await _disposeDetail(tester);
  });

  testWidgets('fix round failed replacement permits guarded manual save',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('failed-edit-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final original = _completedRow(
      storage,
      id: 'failed-edit',
      transcript: 'Retained transcript',
      attempt: 2,
      requestId: 'request-failed',
      jobId: 'job-failed',
      meetingNotes: 'Keep notes',
    );
    await tester.runAsync(() async {
      await seedFileFixtureRow(db, original);
      await storage.pathFor(original.id).writeAsBytes([1, 2, 3]);
    });
    await _mountDetail(
      tester,
      db,
      storage,
      fake,
      service,
      bound,
      original,
      live: true,
    );
    await tester.runAsync(() async {
      await seedFileFixtureRow(
        db,
        original.copyWith(
          transcriptionStatus: 'failed',
          transcriptionError: const Value('replacement rejected'),
        ),
      );
    });
    await tester.pump();
    final editor = find.byKey(const ValueKey('transcript-editor-failed-edit'));
    await tester.enterText(editor, 'Corrected retained transcript');
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('save-transcript-failed-edit')),
    );
    expect(button.onPressed, isNotNull);
    await tester.runAsync(() async {
      button.onPressed!();
    });
    await _pumpRealUntil(tester, () async {
      final file = storage.metaPathFor(original.id);
      return await file.exists() &&
          (jsonDecode(await file.readAsString()) as Map)['transcript'] ==
              'Corrected retained transcript';
    });
    await tester.runAsync(() async {
      final saved = (await db.getDump(original.id))!;
      expect(saved.transcriptionStatus, 'failed');
      expect(saved.transcriptionError, 'replacement rejected');
      expect(saved.transcriptionAttempt, 2);
      expect(saved.transcriptionRequestId, 'request-failed');
      expect(saved.meetingNotes, 'Keep notes');
      expect(await storage.readBytes(original.id), [1, 2, 3]);
    });
    await tester.pump();
    expect(find.text('Transcript saved'), findsOneWidget);
    await _disposeDetail(tester);
  });

  testWidgets('fix round typing during blocked save remains dirty',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('typing-save-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    final release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final original = _completedRow(
      storage,
      id: 'typing-save',
      transcript: 'Original',
      attempt: 2,
      requestId: 'request-typing',
      jobId: 'job-typing',
    );
    await tester.runAsync(() async {
      await seedFileFixtureRow(db, original);
    });

    await _mountDetail(
      tester,
      db,
      storage,
      fake,
      service,
      bound,
      original,
      live: true,
    );

    late Future<void> lock;
    await tester.runAsync(() async {
      lock = bound.access.runSerializedMetadataWrite<void>(
        fileFixtureKey(original.id),
        (_) => release.future,
      );
    });
    final editor = find.byKey(const ValueKey('transcript-editor-typing-save'));
    final save = find.byKey(const ValueKey('save-transcript-typing-save'));
    await tester.enterText(editor, 'Submitted value');
    await tester.pump();
    await tester.runAsync(() async {
      tester.widget<FilledButton>(save).onPressed!();
    });
    await _pumpRealUntil(
      tester,
      () =>
          ProviderScope.containerOf(
            tester.element(find.byType(DumpDetailScreen)),
          ).read(dumpByIdProvider(original.id)).valueOrNull?.transcript ==
          'Submitted value',
    );

    await tester.enterText(editor, 'Newer unsaved draft');
    await tester.pump();

    release.complete();
    await _pumpRealUntil(
      tester,
      () => find
          .descendant(
            of: save,
            matching: find.byType(CircularProgressIndicator),
          )
          .evaluate()
          .isEmpty,
    );

    await tester.runAsync(() => lock);
    expect(_editorText(tester, original.id), 'Newer unsaved draft');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(find.text('Transcript saved'), findsNothing);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(save).onPressed!();
    });
    // Absent before this submission (above); the first save left a newer dirty
    // draft. This success message therefore belongs to the second save, and
    // _saveTranscript sets it only after awaited bound sidecar publication.
    await _pumpRealUntil(
      tester,
      () => find.text('Transcript saved').evaluate().isNotEmpty,
    );
    final metadata = await tester.runAsync(
      () => storage.metaPathFor(original.id).readAsString(),
    );
    expect(
      (jsonDecode(metadata!) as Map)['transcript'],
      'Newer unsaved draft',
    );
    await _disposeDetail(tester);
  });

  for (final failed in [false, true]) {
    testWidgets(
        'fix round manual sidecar failure repairs and permits retry ${failed ? "failed" : "completed"}',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      final temp = Directory.systemTemp.createTempSync('manual-sidecar-');
      final db = LocalDb.forTesting(NativeDatabase.memory());
      final storage = AudioStorage.test(temp);
      final bound = await createBoundServiceFixture(db, registerDrain: false);
      final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
      addTearDown(() async {
        await disposeBoundWidget(tester, bound);
        await db.close();
        temp.deleteSync(recursive: true);
      });
      final original = _completedRow(
        storage,
        id: 'manual-sidecar',
        transcript: 'Original',
        attempt: 0,
        requestId: 'unused',
        jobId: 'unused',
        meetingNotes: 'Keep notes',
      ).copyWith(
        transcriptionStatus: failed ? 'failed' : 'completed',
        transcriptionRequestId: const Value(null),
        transcriptionJobId: const Value(null),
        transcriptionError: Value(failed ? 'replacement rejected' : null),
      );
      final obstacle = Directory(storage.metaPathFor(original.id).path);
      await tester.runAsync(() async {
        await seedFileFixtureRow(db, original);
        await storage.pathFor(original.id).writeAsBytes([1, 2, 3]);
        await obstacle
            .create(); // Real filesystem write failure, not a mocked DB.
      });
      await _mountDetail(
        tester,
        db,
        storage,
        fake,
        null, // Exercise the production app-scoped recovery owner.
        bound,
        original,
        live: true,
      );
      final editor =
          find.byKey(const ValueKey('transcript-editor-manual-sidecar'));
      final save = find.byKey(const ValueKey('save-transcript-manual-sidecar'));
      await tester.enterText(editor, 'First correction');
      await tester.pump();
      await tester.runAsync(() async {
        tester.widget<FilledButton>(save).onPressed!();
      });
      await _pumpRealUntil(
        tester,
        () =>
            ProviderScope.containerOf(
              tester.element(find.byType(DumpDetailScreen)),
            ).read(dumpByIdProvider(original.id)).valueOrNull?.transcript ==
            'First correction',
      );
      await _pumpRealUntil(
        tester,
        () => find
            .descendant(
              of: save,
              matching: find.byType(CircularProgressIndicator),
            )
            .evaluate()
            .isEmpty,
      );
      late DumpRow repairRevision;
      await tester.runAsync(() async {
        final committed = (await db.getDump(original.id))!;
        repairRevision = committed;
        expect(
          committed.transcriptionError,
          startsWith('sidecar_sync_pending:'),
        );
        expect(
          (await db.dumpsNeedingTranscriptionRecovery()).map((r) => r.id),
          contains(original.id),
        );
        await obstacle.delete();
        // The save failure schedules recovery; no explicit scan is requested.
      });
      // Observe this pending revision's automatic acknowledgement, not an
      // initial idle row. Keep live Drift callbacks in the pumping test zone.
      await _pumpRealUntil(tester, () {
        final repaired = ProviderScope.containerOf(
          tester.element(find.byType(DumpDetailScreen)),
        ).read(dumpByIdProvider(original.id)).valueOrNull;
        return repaired != null &&
            repaired.transcript == repairRevision.transcript &&
            repaired.transcriptionAttempt ==
                repairRevision.transcriptionAttempt &&
            repaired.transcriptionRequestId ==
                repairRevision.transcriptionRequestId &&
            repaired.transcriptionStatus == repairRevision.transcriptionStatus &&
            repaired.transcriptionError ==
                LocalDb.errorAfterSidecarSync(repairRevision.transcriptionError);
      });
      // The observed acknowledgement happens within the repair's bound FIFO.
      // Join behind it to observe actual lease settlement. This no-op neither
      // writes metadata nor starts/scans recovery; pump both async zones.
      await pumpBoundUntil(tester, () async {
        await bound.access.runSerializedMetadataWrite<void>(
          fileFixtureKey(original.id),
          (_) async {},
        );
        return true;
      });
      final repairedMetadata = await tester.runAsync(
        () => storage.metaPathFor(original.id).readAsString(),
      );
      expect(
        (jsonDecode(repairedMetadata!) as Map)['transcript'],
        'First correction',
      );
      await tester.enterText(editor, 'Second correction');
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(find.text('Transcript saved'), findsNothing);
      await tester.runAsync(() async {
        tester.widget<FilledButton>(save).onPressed!();
      });
      await _pumpRealUntil(
        tester,
        // Newly emitted for this submission only, after awaited publication.
        () => find.text('Transcript saved').evaluate().isNotEmpty,
      );
      final savedMetadata = await tester.runAsync(
        () => storage.metaPathFor(original.id).readAsString(),
      );
      expect(
        (jsonDecode(savedMetadata!) as Map)['transcript'],
        'Second correction',
      );
      await tester.runAsync(() async {
        final saved = (await db.getDump(original.id))!;
        expect(saved.transcriptionStatus, original.transcriptionStatus);
        expect(saved.transcriptionError, original.transcriptionError);
        expect(saved.transcriptionAttempt, 0);
        expect(saved.transcriptionRequestId, isNull);
        expect(saved.meetingNotes, 'Keep notes');
        expect(await storage.readBytes(original.id), [1, 2, 3]);
        expect(fake.enqueueCalls, 0);
      });
      await _disposeDetail(tester);
    });
  }

  for (final failed in [false, true]) {
    for (final pauseReturn in [false, true]) {
      for (final replace in [false, true]) {
        testWidgets(
            'round 2 sidecar repair outlives route ${failed ? "failed" : "completed"} ${pauseReturn ? "pending DB return" : "blocked serializer"} replacement=$replace',
            (tester) async {
          tester.view.physicalSize = const Size(1080, 2600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          final temp = Directory.systemTemp.createTempSync('unmounted-repair-');
          final db = _PausedTranscriptReturnDb()..pauseReturn = pauseReturn;
          final storage = AudioStorage.test(temp);
          final bound =
              await createBoundServiceFixture(db, registerDrain: false);
          final oldClient =
              _FakeTranscriptionClient(completedTranscript: 'no network');
          final newClient =
              _FakeTranscriptionClient(completedTranscript: 'no network');
          final container = ProviderContainer(
            overrides: [
              localDbProvider.overrideWithValue(db),
              recordingMutationsProvider.overrideWithValue(bound.mutations),
              recordingAccessProvider.overrideWithValue(bound.access),
              audioStorageProvider.overrideWithValue(storage),
              transcriptionClientProvider.overrideWith((_) => oldClient),
              recordingPlaybackEngineFactoryProvider
                  .overrideWithValue(_TestPlaybackEngine.new),
            ],
          );
          late ProviderSubscription<ServerTranscriptionService> subscription;
          final releaseWrite = Completer<void>();
          addTearDown(() async {
            if (!releaseWrite.isCompleted) releaseWrite.complete();
            if (!db.release.isCompleted) db.release.complete();
            subscription.close();
            container.dispose();
            await disposeBoundWidget(tester, bound);
            await db.close();
            temp.deleteSync(recursive: true);
          });
          final original = _completedRow(
            storage,
            id: 'unmounted-repair',
            transcript: 'Original',
            attempt: 2,
            requestId: 'retained-request',
            jobId: 'retained-job',
            meetingNotes: 'Keep notes',
          ).copyWith(
            transcriptionStatus: failed ? 'failed' : 'completed',
            transcriptionRequestId:
                Value(pauseReturn ? null : 'retained-request'),
            transcriptionError: Value(failed ? 'original failure' : null),
          );
          final obstacle = Directory(storage.metaPathFor(original.id).path);
          late Future<void> heldWrite;
          await tester.runAsync(() async {
            await seedFileFixtureRow(db, original);
            await storage.pathFor(original.id).writeAsBytes([3, 1, 4]);
            container.read(transcriptionRecoveryOwnerProvider);
            subscription = container.listen(
              serverTranscriptionServiceProvider,
              (_, __) {},
            );
            await container
                .read(serverTranscriptionServiceProvider)
                .reconcilePending();
            await obstacle.create();
            heldWrite = bound.access.runSerializedMetadataWrite<void>(
              fileFixtureKey(original.id),
              (_) => releaseWrite.future,
            );
          });
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                navigatorKey: navigator,
                home: const Scaffold(body: Text('Home kept alive')),
              ),
            ),
          );
          unawaited(
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => DumpDetailScreen(
                  dumpId: original.id,
                  audioPath: original.audioPath,
                  durationSeconds: 4,
                ),
              ),
            ),
          );
          await tester.pump();
          await pumpBoundUntil(
            tester,
            () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
          );
          await tester.pumpAndSettle();
          await _pumpRealUntil(
            tester,
            () =>
                container.read(dumpByIdProvider(original.id)).valueOrNull !=
                null,
          );
          await tester.pump();
          final editor =
              find.byKey(ValueKey('transcript-editor-${original.id}'));
          final save = find.byKey(ValueKey('save-transcript-${original.id}'));
          await tester.enterText(editor, 'Committed correction');
          await tester.pump();
          await tester.runAsync(() async {
            tester.widget<FilledButton>(save).onPressed!();
          });
          await _pumpRealUntil(tester, () => db.committed.isCompleted);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.byType(DumpDetailScreen), findsNothing);
          expect(find.text('Home kept alive'), findsOneWidget);
          await tester.runAsync(() async {
            if (replace) {
              container.read(transcriptionClientProvider.notifier).state =
                  newClient;
              container.read(serverTranscriptionServiceProvider);
            }
            if (pauseReturn) db.release.complete();
          });
          await tester.pump();
          releaseWrite.complete();
          await tester.pump();
          await tester.runAsync(() => heldWrite);
          var drained = false;
          await tester.runAsync(() async {
            unawaited(
              bound.access.runSerializedMetadataWrite<void>(
                  fileFixtureKey(original.id), (_) async {
                drained = true;
              }),
            );
          });
          await _pumpRealUntil(tester, () => drained);
          await tester.runAsync(() async {
            expect(
              (await db.getDump(original.id))!.transcriptionError,
              startsWith('sidecar_sync_pending:'),
            );
            await obstacle.delete();
          });
          // No explicit scan, resume, remount, or second save after navigation.
          await _pumpRealUntil(
            tester,
            () async => storage.metaPathFor(original.id).exists(),
          );
          await _pumpRealUntil(
            tester,
            () async =>
                (await db.getDump(original.id))!.transcriptionError ==
                original.transcriptionError,
          );
          await tester.runAsync(() async {
            final saved = (await db.getDump(original.id))!;
            final metadata = jsonDecode(
              await storage.metaPathFor(original.id).readAsString(),
            ) as Map;
            expect(saved.transcriptionStatus, original.transcriptionStatus);
            expect(
              saved.transcriptionRequestId,
              original.transcriptionRequestId,
            );
            expect(saved.transcriptionAttempt, original.transcriptionAttempt);
            expect(saved.meetingNotes, 'Keep notes');
            expect(metadata['transcript'], 'Committed correction');
            expect(metadata['transcriptionError'], original.transcriptionError);
            expect(await storage.readBytes(original.id), [3, 1, 4]);
            expect(
              oldClient.createCalls +
                  oldClient.uploadCalls +
                  oldClient.enqueueCalls,
              0,
            );
            expect(
              newClient.createCalls +
                  newClient.uploadCalls +
                  newClient.enqueueCalls,
              0,
            );
          });
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets('stale transcript draft cannot overwrite a newer result',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-edit-stale-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final now = DateTime.utc(2026, 9, 15, 10);
    final row = _completedRow(
      storage,
      id: 'edit-stale',
      mode: 'meeting',
      transcript: 'Original result',
      meetingNotes: 'Original notes',
      attempt: 1,
      requestId: 'request-one',
      jobId: 'job-one',
      now: now,
    );
    await seedFileFixtureRow(db, row);
    final rawAudio = <int>[1, 6, 1, 8, 0, 3];
    storage.pathFor(row.id).writeAsBytesSync(rawAudio);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);
    // Option B: expand the collapsed meeting transcript before drafting.
    await tester.tap(find.byKey(ValueKey('transcript-header-${row.id}')));
    await tester.pump();
    final editorFinder = find.byKey(ValueKey('transcript-editor-${row.id}'));
    await tester.enterText(editorFinder, 'Unsaved stale draft');
    await tester.pump();

    late DumpRow newer;
    await tester.runAsync(() async {
      final nextAttempt = await db.beginTranscriptionAttempt(
        row.id,
        storageKey: fileFixtureKey(row.id),
        requestId: 'request-two',
        now: now.add(const Duration(minutes: 1)),
      );
      await db.completeTranscriptionAttempt(
        row.id,
        storageKey: fileFixtureKey(row.id),
        attempt: nextAttempt.transcriptionAttempt,
        requestId: nextAttempt.transcriptionRequestId!,
        transcript: 'Newer server result',
        meetingNotes: 'Newer notes',
        now: now.add(const Duration(minutes: 2)),
      );
      newer = (await db.getDump(row.id))!;
      // Replacement completion preserves notes; only explicit regeneration
      // may install this newer fixture revision.
      newer = await db.updateDumpMeetingNotes(
        row.id,
        storageKey: fileFixtureKey(row.id),
        expectedTitle: newer.title,
        expectedTranscript: newer.transcript!,
        expectedTranscriptionAttempt: newer.transcriptionAttempt,
        expectedTranscriptionRequestId: newer.transcriptionRequestId,
        meetingNotes: 'Newer notes',
        now: now.add(const Duration(minutes: 3)),
      );
      await storage
          .metaPathFor(row.id)
          .writeAsString(jsonEncode(dumpMetadata(newer)));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(_editorText(tester, row.id), 'Unsaved stale draft');
    final saveFinder = find.byKey(ValueKey('save-transcript-${row.id}'));
    expect(tester.widget<FilledButton>(saveFinder).onPressed, isNotNull);
    await _invokeButton(tester, saveFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    late DumpRow after;
    late Map<String, dynamic> sidecar;
    await tester.runAsync(() async {
      after = (await db.getDump(row.id))!;
      sidecar = jsonDecode(await storage.metaPathFor(row.id).readAsString())
          as Map<String, dynamic>;
    });
    expect(after.transcript, 'Newer server result');
    expect(after.meetingNotes, 'Newer notes');
    expect(after.transcriptionAttempt, 2);
    expect(after.transcriptionRequestId, 'request-two');
    expect(sidecar['transcript'], 'Newer server result');
    expect(find.textContaining('newer transcription'), findsOneWidget);
    expect(_editorText(tester, row.id), 'Unsaved stale draft');
    expect(storage.pathFor(row.id).readAsBytesSync(), rawAudio);

    await _disposeDetail(tester);
  });

  testWidgets('Meeting detail prioritizes notes and keeps transcript editable',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-detail-meeting-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
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
    await seedFileFixtureRow(db, row);
    storage.pathFor('meeting-detail').writeAsBytesSync([1, 2, 3]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
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
    await pumpBoundUntil(
      tester,
      () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(find.text('Meeting Notes'), findsOneWidget);
    expect(find.textContaining('Quoted summary.'), findsOneWidget);
    // Option B: the transcript is collapsed until the header is tapped.
    await tester.tap(
      find.byKey(const ValueKey('transcript-header-meeting-detail')),
    );
    await tester.pumpAndSettle();
    final transcriptEditor = tester.widget<TextField>(
      find.byKey(const ValueKey('transcript-editor-meeting-detail')),
    );
    expect(transcriptEditor.controller!.text, 'Exact raw transcript words.');
    expect(transcriptEditor.maxLines, isNull);
    expect(transcriptEditor.keyboardType, TextInputType.multiline);

    await tester.enterText(
      find.byKey(const ValueKey('title-editor-meeting-detail')),
      'Renamed launch meeting',
    );
    final saveButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    expect(find.text('Saved'), findsNothing);
    final titleDeadline = DateTime.now().add(const Duration(seconds: 2));
    await tester.runAsync(() async {
      saveButton.onPressed!();
    });
    await _pumpRealUntil(tester, () {
      // Keep the original two-second bound, not the helper's longer default.
      if (DateTime.now().isAfter(titleDeadline)) {
        fail('title sidecar did not finish');
      }
      // _save emits this only after bound publication and edit lease close.
      return find.text('Saved').evaluate().isNotEmpty;
    });
    final titleMetadata = await tester.runAsync(
      () => storage.metaPathFor('meeting-detail').readAsString(),
    );
    expect(
      (jsonDecode(titleMetadata!) as Map<String, dynamic>)['title'],
      'Renamed launch meeting',
    );
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);

    final notesButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('regenerate-notes-meeting-detail')),
    );
    expect(find.text('Meeting notes updated'), findsNothing);
    final notesDeadline = DateTime.now().add(const Duration(seconds: 2));
    await tester.runAsync(() async {
      notesButton.onPressed!();
    });
    await _pumpRealUntil(tester, () {
      if (DateTime.now().isAfter(notesDeadline)) {
        fail('meeting-notes sidecar did not finish');
      }
      // A new, distinct success emitted after awaited publication/settlement.
      return find.text('Meeting notes updated').evaluate().isNotEmpty;
    });
    final notesMetadata = await tester.runAsync(
      () => storage.metaPathFor('meeting-detail').readAsString(),
    );
    final metadata = jsonDecode(notesMetadata!) as Map<String, dynamic>;
    expect(
      metadata['meetingNotes'],
      isNot('# Launch\n\n## Summary\n\nQuoted summary.'),
    );
    await tester.pump();
    expect(find.text('Meeting notes updated'), findsOneWidget);

    final saved = (await db.getDump('meeting-detail'))!;
    expect(saved.title, 'Renamed launch meeting');
    expect(saved.transcript, 'Exact raw transcript words.');
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcriptionRequestId, 'request-meeting-detail');
    expect(saved.transcriptionJobId, 'job-meeting-detail');
    expect(saved.transcriptionAttempt, 2);
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
      'meeting detail collapses the transcript behind a summary header',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-collapse-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = _completedRow(
      storage,
      id: 'collapse-meeting',
      mode: 'meeting',
      transcript: '[00:00] Sixteen words of paragraph one here now. '
          'Words continue.\n\n[01:00] Final four more words.',
      meetingNotes: null,
      attempt: 1,
      requestId: 'request-collapse',
      jobId: 'job-collapse',
    );
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);

    // Collapsed by default: header visible with duration + word count,
    // editor not built.
    final header = find.byKey(ValueKey('transcript-header-${row.id}'));
    expect(header, findsOneWidget);
    expect(
      find.textContaining('13 words'),
      findsOneWidget,
      reason: 'header summarises the transcript size, markers excluded',
    );
    expect(
      find.byKey(ValueKey('transcript-editor-${row.id}')),
      findsNothing,
      reason: 'transcript starts collapsed for meeting dumps',
    );
    expect(
      find.byKey(ValueKey('save-transcript-${row.id}')),
      findsNothing,
    );
    // Notes are absent, so no Meeting Notes heading and no filler.
    expect(find.text('Meeting Notes'), findsNothing);
    // Generate stays reachable without expanding the transcript.
    expect(
      find.byKey(ValueKey('generate-notes-${row.id}')),
      findsOneWidget,
    );

    // Expanding reveals the standard editor and save button.
    await tester.tap(header);
    await tester.pumpAndSettle();
    final editor = tester.widget<TextField>(
      find.byKey(ValueKey('transcript-editor-${row.id}')),
    );
    expect(editor.controller!.text, row.transcript);
    expect(editor.maxLines, isNull);
    expect(
      find.byKey(ValueKey('save-transcript-${row.id}')),
      findsOneWidget,
    );

    // Collapsing again removes the editor without losing the dump.
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('transcript-editor-${row.id}')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'non-meeting detail keeps the transcript editor expanded inline',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-inline-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = _completedRow(
      storage,
      id: 'inline-dump',
      mode: 'brain_dump',
      transcript: 'Plain dump transcript.',
      meetingNotes: null,
      attempt: 1,
      requestId: 'request-inline',
      jobId: 'job-inline',
    );
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    storage
        .metaPathFor(row.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(row)));

    await _mountDetail(tester, db, storage, fake, service, bound, row);

    expect(
      find.byKey(ValueKey('transcript-header-${row.id}')),
      findsNothing,
      reason: 'only meeting dumps collapse the transcript',
    );
    expect(_editorText(tester, row.id), 'Plain dump transcript.');

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
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
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
    await seedFileFixtureRow(db, original);
    storage.pathFor(original.id).writeAsBytesSync([1, 2, 3]);
    storage
        .metaPathFor(original.id)
        .writeAsStringSync(jsonEncode(dumpMetadata(original)));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
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
        storageKey: fileFixtureKey(original.id),
        requestId: 'request-attempt-2',
        now: now.add(const Duration(minutes: 1)),
      );
      final completed = await db.completeTranscriptionAttempt(
        original.id,
        storageKey: fileFixtureKey(original.id),
        attempt: newerAttempt.transcriptionAttempt,
        requestId: newerAttempt.transcriptionRequestId!,
        transcript: original.transcript!,
        meetingNotes: 'attempt two notes',
        now: now.add(const Duration(minutes: 2)),
      );
      expect(completed, isTrue);
      // Seed an explicitly regenerated notes revision, not completion output.
      await (db.update(db.dumps)..where((d) => d.id.equals(original.id))).write(
        const DumpsCompanion(meetingNotes: Value('attempt two notes')),
      );
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

DumpRow _completedRow(
  AudioStorage storage, {
  required String id,
  required String transcript,
  required int attempt,
  required String requestId,
  required String jobId,
  String mode = 'brain_dump',
  String? meetingNotes,
  DateTime? now,
}) {
  final timestamp = now ?? DateTime.utc(2026, 9, 15);
  return DumpRow(
    id: id,
    createdAt: timestamp,
    updatedAt: timestamp,
    mode: mode,
    durationSeconds: 4,
    title: 'Recording $id',
    transcript: transcript,
    meetingNotes: meetingNotes,
    audioPath: storage.pathFor(id).path,
    audioSizeBytes: 7,
    syncStatus: 'pending',
    syncAttempts: 0,
    transcriptionStatus: 'completed',
    transcriptionRequestId: requestId,
    transcriptionJobId: jobId,
    transcriptionAttempt: attempt,
    transcriptionStartedAt: timestamp,
    transcriptionUpdatedAt: timestamp,
    transcriptionCompletedAt: timestamp,
  );
}

Future<void> _mountDetail(
  WidgetTester tester,
  LocalDb db,
  AudioStorage storage,
  TranscriptionClient client,
  ServerTranscriptionService? service,
  BoundServiceFixture bound,
  DumpRow row, {
  bool live = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localDbProvider.overrideWithValue(db),
        recordingMutationsProvider.overrideWithValue(bound.mutations),
        recordingAccessProvider.overrideWithValue(bound.access),
        audioStorageProvider.overrideWithValue(storage),
        transcriptionClientProvider.overrideWith((_) => client),
        if (service != null)
          serverTranscriptionServiceProvider.overrideWith((_) => service),
        if (!live)
          dumpByIdProvider(row.id).overrideWith((_) => Stream.value(row)),
        recordingPlaybackEngineFactoryProvider.overrideWithValue(
          _TestPlaybackEngine.new,
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
  if (live) {
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DumpDetailScreen)),
      );
      await container.read(dumpByIdProvider(row.id).future);
      if (service == null) {
        // main() bootstraps recovery before showing detail routes.
        container.read(transcriptionRecoveryOwnerProvider);
        await container
            .read(serverTranscriptionServiceProvider)
            .reconcilePending();
      }
    });
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await pumpBoundUntil(
    tester,
    () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
  );
}

Future<void> _pumpRealUntil(
  WidgetTester tester,
  FutureOr<bool> Function() predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final done = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return await predicate();
    });
    await tester.pump(const Duration(milliseconds: 10));
    if (done == true) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('real reactive condition timed out');
    }
  }
}

Future<void> _invokeButton(WidgetTester tester, Finder finder) async {
  final button = tester.widget<FilledButton>(finder);
  await tester.runAsync(() async {
    button.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

String _editorText(WidgetTester tester, String dumpId) => tester
    .widget<TextField>(find.byKey(ValueKey('transcript-editor-$dumpId')))
    .controller!
    .text;

Future<void> _waitForRealCondition(
  FutureOr<bool> Function() predicate, {
  required String description,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<DumpRow> _waitForRow(
  LocalDb db,
  String id,
  bool Function(DumpRow row) predicate,
) async {
  DumpRow? result;
  await _waitForRealCondition(
    () async {
      final row = await db.getDump(id);
      if (row == null || !predicate(row)) return false;
      result = row;
      return true;
    },
    description: 'dump $id',
  );
  return result!;
}

Future<Map<String, dynamic>> _waitForMetadata(
  AudioStorage storage,
  String id,
  bool Function(Map<String, dynamic> metadata) predicate,
) async {
  Map<String, dynamic>? result;
  await _waitForRealCondition(
    () async {
      final sidecar = storage.metaPathFor(id);
      if (!await sidecar.exists()) return false;
      final metadata =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      if (!predicate(metadata)) return false;
      result = metadata;
      return true;
    },
    description: 'metadata $id',
  );
  return result!;
}

Future<void> _disposeDetail(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
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
