// SPDX-License-Identifier: AGPL-3.0-or-later
// Positive regressions adapted from Ted's preserved R2-S1 fault probe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/services/transcription_client.dart';
import '../support/resolved_temp.dart';

class PausedReturnDb extends LocalDb {
  PausedReturnDb() : super.forTesting(NativeDatabase.memory());
  final committed = Completer<DumpRow>();
  final release = Completer<void>();
  int begins = 0;
  final acknowledgements = <String?>[];
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
    if (!committed.isCompleted) {
      committed.complete(saved);
      // Production transaction completed; no DB lock held.
      await release.future;
    }
    return saved;
  }

  @override
  Future<DumpRow> beginTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required String requestId,
    required DateTime now,
  }) {
    begins++;
    return super.beginTranscriptionAttempt(
      id,
      storageKey: storageKey,
      requestId: requestId,
      now: now,
    );
  }

  @override
  Future<bool> updateTranscriptionSidecarError(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String? requestId,
    required String? error,
    required DateTime now,
    String? expectedTranscript,
    String? expectedError,
  }) async {
    final won = await super.updateTranscriptionSidecarError(
      id,
      storageKey: storageKey,
      attempt: attempt,
      requestId: requestId,
      error: error,
      now: now,
      expectedTranscript: expectedTranscript,
      expectedError: expectedError,
    );
    if (won) acknowledgements.add(expectedError);
    return won;
  }
}

// The actual AudioStorage per-recording serializer remains the sole lock.
// Only the raw-write callback is intercepted. Normal writes call the actual
// production callback. One armed write reproduces _writeMetadataFile: flush
// temp, remove existing target, then fail finalization before rename succeeds.
// This does NOT bypass serialization, create a .tmp obstacle, mutate SQLite,
// or delete a sidecar from a concurrent actor.
class FinalizationSeam implements AudioStorage {
  FinalizationSeam(this.inner, this.db);
  final AudioStorage inner;
  final LocalDb db;
  bool failNext = false;
  Completer<void>? releaseFailure;
  int writes = 0;
  int failures = 0;
  int active = 0;
  int maxActive = 0;
  int finishedOperations = 0;
  int startedOperations = 0;
  int currentOperation = 0;
  final writeOperations = <int>[];
  final pendingAtWrite = <bool>[];
  @override
  Future<T> runSerializedMetadataWrite<T>(
    String id,
    Future<T> Function(Future<void> Function(Map<String, dynamic>) write)
        operation,
  ) {
    final operationId = ++startedOperations;
    return inner.runSerializedMetadataWrite<T>(id, (productionWrite) async {
      active++;
      if (active > maxActive) maxActive = active;
      try {
        return await operation((metadata) async {
          writes++;
          writeOperations.add(operationId);
          final row = (await db.getDump(id))!;
          final pending =
              row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                  false;
          pendingAtWrite.add(pending);

          if (!failNext) {
            await productionWrite(metadata);
            return;
          }
          failNext = false; // One-shot fault: automatic retry would succeed.
          final target = inner.metaPathFor(id);
          final tmp = File('${target.path}.tmp');
          expect(
            await target.exists(),
            isTrue,
            reason: 'a good target exists before the finalization fault',
          );
          await tmp.writeAsString(jsonEncode(metadata), flush: true);
          expect(await tmp.exists(), isTrue);
          if (await target.exists()) await target.delete();
          expect(await target.exists(), isFalse);
          failures++;
          if (releaseFailure != null) await releaseFailure!.future;
          throw FileSystemException(
            'R2S1 injected rename/finalization failure',
            tmp.path,
          );
        });
      } finally {
        active--;
        finishedOperations++;
      }
    });
  }

  @override
  File pathFor(String id) => inner.pathFor(id);
  @override
  File metaPathFor(String id) => inner.metaPathFor(id);
  @override
  Future<Uint8List> readBytes(String id) => inner.readBytes(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BackendIo<T> implements IoOperation<T> {
  _BackendIo(this.id, Future<T> Function() body) {
    result = _run(body);
  }

  @override
  final String id;
  @override
  late final Future<T> result;
  final Completer<void> _done = Completer<void>();
  @override
  Future<void> get settled => _done.future;

  Future<T> _run(Future<T> Function() body) async {
    try {
      return await body();
    } finally {
      _done.complete();
    }
  }
}

final class FinalizationBackend extends FilesystemStorageBackend {
  FinalizationBackend(this.seam);

  final FinalizationSeam seam;

  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) {
    return _BackendIo<Outcome<void>>(operationId, () async {
      {
        seam.writes++;
        seam.writeOperations.add(seam.currentOperation);
        final row = (await seam.db.getDump(binding.key.dumpId))!;
        seam.pendingAtWrite.add(
          row.transcriptionError?.startsWith('sidecar_sync_pending:') ?? false,
        );
        if (!seam.failNext) {
          final io = super.writeMetadata(binding, metadata, operationId);
          final result = await io.result;
          await io.settled;
          return result;
        }
        seam.failNext = false;
        final target = seam.inner.metaPathFor(binding.key.dumpId);
        final tmp = File('${target.path}.tmp');
        expect(await target.exists(), isTrue);
        await tmp.writeAsString(jsonEncode(metadata), flush: true);
        if (await target.exists()) await target.delete();
        seam.failures++;
        if (seam.releaseFailure != null) await seam.releaseFailure!.future;
        return const Fail<void>(
          (
            code: ProblemCode.io,
            message: 'R2S1 injected rename/finalization failure',
          ),
        );
      }
    });
  }
}

// Observe admissions and callback completion, including no-op publication.
// Production bound FIFO and filesystem writer remain authoritative.
final class ObservedPublicationAccess extends BoundRecordingAccess {
  ObservedPublicationAccess({
    required super.db,
    required super.backend,
    required super.mutations,
    required this.seam,
  });
  final FinalizationSeam seam;
  @override
  Future<T> runSerializedMetadataWrite<T>(
    RecordingKey key,
    Future<T> Function(MetadataPublicationAccess) operation,
  ) {
    final operationId = ++seam.startedOperations;
    return super.runSerializedMetadataWrite<T>(key, (writer) async {
      seam.currentOperation = operationId;
      seam.active++;
      if (seam.active > seam.maxActive) seam.maxActive = seam.active;
      try {
        return await operation(writer);
      } finally {
        seam.active--;
        seam.finishedOperations++;
      }
    });
  }
}

class NoNetwork implements TranscriptionClient {
  final calls = <String>[];
  @override
  String get baseUrl => 'http://isolated.invalid';
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString());
    throw StateError('Unexpected network call ${invocation.memberName}');
  }
}

class Playback implements RecordingPlaybackEngine {
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

Future<void> until(
  WidgetTester tester,
  FutureOr<bool> Function() condition,
) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    bool? done;
    Object? failure;
    StackTrace? failureStack;
    await tester.runAsync(() async {
      // Keep pumping while a real DB read awaits fake-zone query cleanup.
      unawaited(
        Future<bool>.sync(condition).then<void>(
          (value) {
            done = value;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            failureStack = stack;
          },
        ),
      );
    });
    do {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (DateTime.now().isAfter(end)) fail('Publication condition timed out');
    } while (done == null && failure == null);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    if (done == true) return;
  }
}

void manualTranscriptPublicationTests() {
  for (final nullId in [false, true]) {
    testWidgets(
      'round 3 protected owner finalization failure nullId=$nullId',
      (tester) => scenario(
        tester,
        unmount: true,
        failed: true,
        nullId: nullId,
        inject: false,
        failOwner: true,
      ),
    );
  }
  for (final newerText in [
    'Committed corrected transcript',
    'Newer correction',
  ]) {
    testWidgets(
      'round 3 older route cannot publish newer revision $newerText',
      (tester) => scenario(
        tester,
        unmount: false,
        failed: true,
        nullId: true,
        inject: false,
        newerText: newerText,
      ),
    );
  }
  for (final unmount in [false, true]) {
    for (final failed in [false, true]) {
      for (final nullId in [false, true]) {
        testWidgets(
          'round 3 acknowledged publication unmount=$unmount failed=$failed nullId=$nullId',
          (tester) => scenario(
            tester,
            unmount: unmount,
            failed: failed,
            nullId: nullId,
            inject: true,
          ),
        );
      }
    }
    testWidgets(
      'round 3 healthy publication control unmount=$unmount',
      (tester) => scenario(
        tester,
        unmount: unmount,
        failed: true,
        nullId: true,
        inject: false,
      ),
    );
  }
}

Future<void> scenario(
  WidgetTester tester, {
  required bool unmount,
  required bool failed,
  required bool nullId,
  required bool inject,
  String? newerText,
  bool failOwner = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final temp = createResolvedTempSync('manual-publication-');
  final db = PausedReturnDb();
  final audio = FinalizationSeam(AudioStorage.test(temp), db);
  final backend = FinalizationBackend(audio);
  final bound = await createBoundServiceFixture(
    db,
    backend: backend,
    registerDrain: false,
  );
  final access = ObservedPublicationAccess(
    db: db,
    backend: backend,
    mutations: bound.mutations,
    seam: audio,
  );
  final client = NoNetwork();
  final container = ProviderContainer(
    overrides: [
      localDbProvider.overrideWithValue(db),
      audioStorageProvider.overrideWithValue(audio.inner),
      storageBackendProvider.overrideWithValue(backend),
      recordingMutationsProvider.overrideWithValue(bound.mutations),
      recordingAccessProvider.overrideWithValue(access),
      transcriptionClientProvider.overrideWith((_) => client),
      recordingPlaybackEngineFactoryProvider.overrideWithValue(Playback.new),
    ],
  );
  addTearDown(() async {
    if (!db.release.isCompleted) db.release.complete();
    if (audio.releaseFailure != null && !audio.releaseFailure!.isCompleted) {
      audio.releaseFailure!.complete();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    var drained = false;
    await tester.runAsync(() async {
      unawaited(bound.mutations.drain().then((_) => drained = true));
    });
    await until(tester, () => drained);

    await tester.runAsync(db.close);

    temp.deleteSync(recursive: true);
  });
  const id = 'isolated-r2-s1';
  final now = DateTime.utc(2026, 9, 15);
  final originalError = failed ? 'original replacement rejection' : null;
  final requestId = nullId ? null : 'retained-request';
  final original = DumpRow(
    id: id,
    createdAt: now,
    updatedAt: now,
    mode: 'meeting',
    durationSeconds: 4,
    title: 'Independent probe',
    transcript: 'Original transcript',
    meetingNotes: 'Original notes retained',
    audioPath: audio.pathFor(id).path,
    audioSizeBytes: 4,
    syncStatus: 'pending',
    syncAttempts: 0,
    transcriptionStatus: failed ? 'failed' : 'completed',
    transcriptionAttempt: 2,
    transcriptionRequestId: requestId,
    transcriptionJobId: 'retained-job',
    transcriptionError: originalError,
  );
  await tester.runAsync(() async {
    await seedFileFixtureRow(db, original);
    await audio.pathFor(id).writeAsBytes([3, 1, 4, 1]);
    if (failOwner) {
      await audio.inner.writeMetadata(id, dumpMetadata(original));
      audio.failNext = true;
      audio.releaseFailure = Completer<void>();
    }
    container.read(transcriptionRecoveryOwnerProvider);
    await container.read(serverTranscriptionServiceProvider).reconcilePending();
  });
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Probe home remains mounted')),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => DumpDetailScreen(
          dumpId: id,
          audioPath: original.audioPath,
          durationSeconds: 4,
        ),
      ),
    ),
  );
  await tester.pump();
  await until(
    tester,
    () =>
        container.read(dumpByIdProvider(id)).valueOrNull != null &&
        find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
  );
  // Option B: meeting transcripts start collapsed — expand before editing.
  await tester.tap(
    find.byKey(const ValueKey('transcript-header-isolated-r2-s1')),
  );
  await tester.pump();
  await tester.enterText(
    find.byKey(const ValueKey('transcript-editor-isolated-r2-s1')),
    'Committed corrected transcript',
  );
  await tester.pump();
  final save = find.byKey(const ValueKey('save-transcript-isolated-r2-s1'));
  await tester.runAsync(() async {
    tester.widget<FilledButton>(save).onPressed!();
  });
  await until(tester, () => db.committed.isCompleted);
  late DumpRow committed;
  await tester.runAsync(() async {
    committed = await db.committed.future;
  });
  expect(
    committed.transcriptionError,
    startsWith('sidecar_sync_pending: manual_edit:'),
  );
  if (failOwner) {
    await until(tester, () => audio.failures == 1);
    await until(tester, () async {
      expect(await audio.metaPathFor(id).exists(), isFalse);
      expect(
        (await db.getDump(id))!.transcriptionError,
        committed.transcriptionError,
      );
      expect(
        (await db.dumpsNeedingTranscriptionRecovery()).map((r) => r.id),
        contains(id),
      );
      expect(db.acknowledgements, isEmpty);
      return true;
    });
    audio.releaseFailure!.complete();
  }
  // No serializer barrier: the real owner can complete before DB result delivery.
  await until(
    tester,
    () async =>
        audio.active == 0 &&
        db.acknowledgements.length == 1 &&
        (await db.getDump(id))!.transcriptionError == originalError,
  );
  await tester.runAsync(() async {
    final metadata =
        jsonDecode(await audio.metaPathFor(id).readAsString()) as Map;
    expect(metadata['transcript'], 'Committed corrected transcript');
    expect(metadata['transcriptionError'], originalError);
    expect(db.acknowledgements, [committed.transcriptionError]);
    expect(await db.dumpsNeedingTranscriptionRecovery(), isEmpty);
    expect(audio.writes, failOwner ? 2 : 1);
    expect(db.release.isCompleted, isFalse);
  });
  if (unmount) {
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(DumpDetailScreen), findsNothing);
    expect(find.text('Probe home remains mounted'), findsOneWidget);
  }
  if (newerText != null) {
    // Put the old route ahead of the new owner in the real serializer. The
    // newer commit occurs before that old operation reads its guarded revision.
    final releaseSerializer = Completer<void>();
    final serializerEntered = Completer<void>();
    late Future<void> held;
    addTearDown(() {
      if (!releaseSerializer.isCompleted) releaseSerializer.complete();
    });
    await tester.runAsync(() async {
      held = access.runSerializedMetadataWrite<void>(fileFixtureKey(id),
          (_) async {
        serializerEntered.complete();
        await releaseSerializer.future;
      });
    });
    await until(tester, () => serializerEntered.isCompleted);
    final oldOperation = audio.startedOperations + 1;

    await tester.runAsync(() async {
      db.release.complete();
    });
    await until(tester, () => audio.startedOperations >= oldOperation);

    late DumpRow newer;
    await tester.runAsync(() async {
      newer = await db.updateDumpTranscript(
        id,
        storageKey: fileFixtureKey(id),
        expectedTranscript: committed.transcript!,
        expectedTranscriptionAttempt: 2,
        expectedTranscriptionRequestId: requestId,
        transcript: newerText,
        now: now,
      );
      expect(newer.transcriptionError, isNot(committed.transcriptionError));
    });
    await until(
      tester,
      () async =>
          (await db.getDump(id))!.transcriptionError ==
          newer.transcriptionError,
    );
    releaseSerializer.complete();
    await until(tester, () async {
      await held;
      return true;
    });
    await until(
      tester,
      () async =>
          audio.active == 0 &&
          (await db.getDump(id))!.transcriptionError == originalError &&
          find
              .descendant(
                of: save,
                matching: find.byType(CircularProgressIndicator),
              )
              .evaluate()
              .isEmpty,
    );
    await tester.runAsync(() async {
      expect(
        audio.writeOperations,
        isNot(contains(oldOperation)),
        reason: 'older route must not write or acknowledge the newer marker',
      );
      expect(audio.writes, 2);
      expect(audio.pendingAtWrite, [true, true]);
      expect(
        db.acknowledgements,
        [committed.transcriptionError, newer.transcriptionError],
      );
      final saved = (await db.getDump(id))!;
      expect(saved.transcript, newerText);
      expect(saved.meetingNotes, original.meetingNotes);
      expect(saved.transcriptionError, originalError);
      expect(saved.transcriptionStatus, original.transcriptionStatus);
      expect(saved.transcriptionAttempt, 2);
      expect(saved.transcriptionRequestId, requestId);
      expect(saved.transcriptionJobId, original.transcriptionJobId);
      expect(
        (jsonDecode(await audio.metaPathFor(id).readAsString())
            as Map)['transcript'],
        newerText,
      );
      expect(db.begins, 0);
      expect(client.calls, isEmpty);
      expect(await audio.readBytes(id), [3, 1, 4, 1]);
    });
    expect(find.text('Transcript saved'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    return;
  }
  audio.failNext = inject;
  final operationsBeforeReturn = audio.finishedOperations;
  await tester.runAsync(() async {
    db.release.complete();
  });
  await until(
    tester,
    () =>
        audio.finishedOperations > operationsBeforeReturn && audio.active == 0,
  );
  if (!unmount) {
    await until(
      tester,
      () => find
          .descendant(
            of: save,
            matching: find.byType(CircularProgressIndicator),
          )
          .evaluate()
          .isEmpty,
    );
  }
  // No explicit scan/resume/remount/resave. Leave production owner alive; a
  // one-shot fault has already reset, so any correctly scheduled retry can work.
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1300)));
  await tester.pump(const Duration(milliseconds: 1300));
  await tester.runAsync(() async {
    final saved = (await db.getDump(id))!;
    final targetExists = await audio.metaPathFor(id).exists();
    final pending = await db.dumpsNeedingTranscriptionRecovery();
    expect(
      targetExists,
      isTrue,
      reason: 'late initiator must preserve acknowledged target',
    );
    expect(audio.pendingAtWrite, failOwner ? [true, true] : [true]);
    expect(
      audio.maxActive,
      1,
      reason: 'both operations use production serializer',
    );
    expect(
      audio.writes,
      failOwner ? 2 : 1,
      reason: 'no redundant mutation after exact acknowledgement',
    );
    expect(audio.failures, failOwner ? 1 : 0);
    expect(
      audio.failNext,
      inject,
      reason: 'armed finalization fault was never reached',
    );
    final metadata =
        jsonDecode(await audio.metaPathFor(id).readAsString()) as Map;
    expect(metadata['transcript'], 'Committed corrected transcript');
    expect(metadata['transcriptionError'], originalError);
    expect(saved.transcript, 'Committed corrected transcript');
    expect(metadata['meetingNotes'], original.meetingNotes);
    expect(metadata['transcriptionAttempt'], original.transcriptionAttempt);
    expect(metadata['transcriptionRequestId'], original.transcriptionRequestId);
    expect(metadata['transcriptionJobId'], original.transcriptionJobId);
    expect(saved.transcriptionError, originalError);
    expect(saved.transcriptionStatus, original.transcriptionStatus);
    expect(saved.transcriptionRequestId, requestId);
    expect(saved.transcriptionJobId, 'retained-job');
    expect(saved.transcriptionAttempt, 2);
    expect(saved.meetingNotes, 'Original notes retained');
    expect(pending, isEmpty);
    expect(db.acknowledgements, [committed.transcriptionError]);
    expect(db.begins, 0);
    expect(client.calls, isEmpty);
    expect(await audio.readBytes(id), [3, 1, 4, 1]);
  });
  if (!unmount) expect(find.text('Transcript saved'), findsOneWidget);
  await tester.pumpWidget(const SizedBox.shrink());
}
