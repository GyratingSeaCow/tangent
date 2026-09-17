// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import '../../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import '../../support/bound_row_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/models/transcription_status.dart';
import 'package:tangent/services/meeting_transcript_formatter.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

/// Test double that skips the network entirely. Returns canned
/// `createDump` / `uploadAudio` / `enqueueTranscription` responses and
/// yields canned SSE events.
class _FakeTranscriptionClient implements TranscriptionClient {
  _FakeTranscriptionClient({
    required this.completedTranscript,
    this.shouldFailCreate = false,
    this.onCreate,
    this.onUpload,
    this.onStreamStart,
    this.afterEvent,
    this.onEnqueue,
    this.onGetJob,
    this.streamForJob,
    this.enqueueError,
    this.streamEvents,
    this.streamError,
  });

  final String completedTranscript;
  final bool shouldFailCreate;
  final FutureOr<void> Function()? onCreate;
  final FutureOr<void> Function()? onUpload;
  final FutureOr<void> Function()? onStreamStart;
  final FutureOr<void> Function(String status)? afterEvent;
  final FutureOr<TranscriptionJobSnapshot> Function(
    String dumpId,
    String requestId,
    String model,
  )? onEnqueue;
  final FutureOr<TranscriptionJobSnapshot> Function(String jobId)? onGetJob;
  final Stream<JobEvent> Function(String jobId)? streamForJob;
  final Object? enqueueError;
  final List<JobEvent>? streamEvents;
  final Object? streamError;

  int createCalls = 0;
  int uploadCalls = 0;
  int enqueueCalls = 0;
  int getJobCalls = 0;
  int streamJobCalls = 0;
  final List<String> enqueueRequestIds = [];
  final List<String> getJobIds = [];
  final List<String> streamJobIds = [];
  final List<List<int>> uploadedAudioBytes = [];
  final List<String> calls = [];

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
    createCalls += 1;
    calls.add('create');
    await onCreate?.call();
    if (shouldFailCreate) {
      throw ApiException(
        statusCode: 500,
        code: 'fail',
        message: 'create failed',
      );
    }
    return id;
  }

  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    uploadCalls += 1;
    calls.add('upload');
    uploadedAudioBytes.add(List<int>.from(audioBytes));
    await onUpload?.call();
  }

  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async {
    enqueueCalls += 1;
    calls.add('enqueue');
    enqueueRequestIds.add(requestId);
    final handler = onEnqueue;
    if (handler != null) return await handler(dumpId, requestId, model);
    if (enqueueError != null) throw enqueueError!;

    return TranscriptionJobSnapshot(
      id: 'job-$dumpId',
      requestId: requestId,
      dumpId: dumpId,
      status: 'queued',
      model: model,
    );
  }

  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async {
    getJobCalls += 1;
    calls.add('getJob');
    getJobIds.add(jobId);
    final handler = onGetJob;
    if (handler != null) return await handler(jobId);
    throw UnimplementedError();
  }

  @override
  Future<ServerInfo> getServerInfo() async => throw UnimplementedError();

  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {
    streamJobCalls += 1;
    calls.add('stream');
    streamJobIds.add(jobId);
    await onStreamStart?.call();
    final handler = streamForJob;
    if (handler != null) {
      yield* handler(jobId);
      return;
    }
    final events = streamEvents ??
        [
          const JobEvent('queued', {}),
          const JobEvent('running', {}),
          JobEvent('completed', {'transcript': completedTranscript}),
        ];
    for (final event in events) {
      yield event;
      await afterEvent?.call(event.status);
    }
    if (streamError != null) throw streamError!;
  }
}

class _PausedOwnershipDb extends LocalDb {
  _PausedOwnershipDb() : super.forTesting(NativeDatabase.memory()) {
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
  }
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DumpRow> beginTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required String requestId,
    required DateTime now,
  }) async {
    entered.complete();
    await release.future;
    return super.beginTranscriptionAttempt(
      id,
      storageKey: storageKey,
      requestId: requestId,
      now: now,
    );
  }
}

class _ObservedRecoveryDb extends LocalDb {
  _ObservedRecoveryDb() : super.forTesting(NativeDatabase.memory());
  int subscriptions = 0;
  int activeSubscriptions = 0;
  int deliveries = 0;
  int scans = 0;

  @override
  Stream<List<DumpRow>> watchDumpsNeedingTranscriptionRecovery() =>
      Stream<List<DumpRow>>.multi((controller) {
        subscriptions++;
        activeSubscriptions++;
        final subscription =
            super.watchDumpsNeedingTranscriptionRecovery().listen(
          (rows) {
            deliveries++;
            controller.add(rows);
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = () async {
          await subscription.cancel();
          activeSubscriptions--;
        };
      });

  @override
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() {
    scans++;
    return super.dumpsNeedingTranscriptionRecovery();
  }
}

Future<void> _eventually(
  FutureOr<bool> Function() condition,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// Passive observation does not resolve a lazy provider. The production provider
// queues its startup scan in a microtask, after this creation/update callback.
class _LateAcceptanceObserver extends ProviderObserver {
  _LateAcceptanceObserver(this.db);
  final _LateAcceptanceDb db;

  void _observe(ProviderBase<Object?> provider, Object? value) {
    if (provider == serverTranscriptionServiceProvider &&
        value is ServerTranscriptionService) {
      db.firstService ??= value;
      db.currentService = value;
    }
  }

  @override
  void didAddProvider(
    ProviderBase<Object?> provider,
    Object? value,
    ProviderContainer container,
  ) =>
      _observe(provider, value);

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) =>
      _observe(provider, newValue);
}

class _LateAcceptanceDb extends LocalDb {
  _LateAcceptanceDb(
    this.pauseRead, {
    this.pauseAfterCommit = false,
    this.holdReplacementQuery = false,
  }) : super.forTesting(NativeDatabase.memory()) {
    addTearDown(() {
      if (!releaseReplacementQuery.isCompleted) {
        releaseReplacementQuery.complete();
      }
      if (!release.isCompleted) release.complete();
    });
  }
  final bool pauseRead;
  final bool pauseAfterCommit;
  final bool holdReplacementQuery;
  final _transactionZoneKey = Object();
  bool admissionReadObserved = false;
  ServerTranscriptionService? firstService;
  ServerTranscriptionService? currentService;
  ServerTranscriptionService? queryService;
  final replacementQueryEntered = Completer<void>();
  final releaseReplacementQuery = Completer<void>();
  final replacementQueryCompleted = Completer<List<DumpRow>>();
  bool armed = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  String? allocatedRequest;
  int scans = 0;
  int allocations = 0;

  // The admission guard also reads the row, inside a SQLite transaction.
  // Pausing that read would lock out the very empty query under test. Preserve
  // the real transaction, and target the service's subsequent outside read.
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) =>
      super.transaction(
        () => runZoned(action, zoneValues: {_transactionZoneKey: true}),
        requireNew: requireNew,
      );

  @override
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() {
    scans++;
    // Capture identity at ENTRY: an old in-flight query completing after a
    // replacement cannot satisfy this generation's completion observation.
    final serviceAtEntry = currentService;
    final observe = serviceAtEntry != null &&
        !identical(serviceAtEntry, firstService) &&
        !replacementQueryEntered.isCompleted;
    if (observe) {
      queryService = serviceAtEntry;
      replacementQueryEntered.complete();
    }
    final query = () async {
      if (observe && holdReplacementQuery) {
        await releaseReplacementQuery.future;
      }
      return super.dumpsNeedingTranscriptionRecovery();
    }();
    if (observe) {
      // Observe the SAME future returned to production, not query entry or an
      // early flag. Completion carries the actual SQLite snapshot unchanged.
      unawaited(
        query.then<void>(
          replacementQueryCompleted.complete,
          onError: replacementQueryCompleted.completeError,
        ),
      );
    }
    return query;
  }

  @override
  Future<DumpRow?> getDump(String id) async {
    final row = await super.getDump(id);
    final inTransaction = Zone.current[_transactionZoneKey] == true;
    if (pauseRead && armed && inTransaction) admissionReadObserved = true;
    if (pauseRead && armed && !inTransaction) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return row;
  }

  @override
  Future<DumpRow> beginTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required String requestId,
    required DateTime now,
  }) async {
    allocatedRequest = requestId;
    allocations++;
    if (pauseAfterCommit && armed) {
      armed = false;
      final accepted = await super.beginTranscriptionAttempt(
        id,
        storageKey: storageKey,
        requestId: requestId,
        now: now,
      );
      entered.complete();
      await release.future;
      return accepted;
    }
    if (!pauseRead && armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return super.beginTranscriptionAttempt(
      id,
      storageKey: storageKey,
      requestId: requestId,
      now: now,
    );
  }
}

class _FlakyRecoveryQueryDb extends LocalDb {
  _FlakyRecoveryQueryDb() : super.forTesting(NativeDatabase.memory());

  int recoveryQueryCalls = 0;

  @override
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() {
    recoveryQueryCalls += 1;
    if (recoveryQueryCalls == 1) {
      throw StateError('recovery query failed');
    }
    return super.dumpsNeedingTranscriptionRecovery();
  }
}

class _PausedRecoveryQueryDb extends LocalDb {
  _PausedRecoveryQueryDb() : super.forTesting(NativeDatabase.memory()) {
    addTearDown(() {
      if (!releaseQuery.isCompleted) releaseQuery.complete();
    });
  }

  final queryStarted = Completer<void>();
  final releaseQuery = Completer<void>();

  @override
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() async {
    final rows = await super.dumpsNeedingTranscriptionRecovery();
    queryStarted.complete();
    await releaseQuery.future;
    return rows;
  }
}

class _FirstSnapshotPausedRecoveryQueryDb extends LocalDb {
  _FirstSnapshotPausedRecoveryQueryDb()
      : super.forTesting(NativeDatabase.memory());

  final firstQueryCaptured = Completer<void>();
  final releaseFirstQuery = Completer<void>();
  int recoveryQueryCalls = 0;

  @override
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() async {
    recoveryQueryCalls += 1;
    final rows = await super.dumpsNeedingTranscriptionRecovery();
    if (recoveryQueryCalls == 1) {
      firstQueryCaptured.complete();
      await releaseFirstQuery.future;
    }
    return rows;
  }
}

class _ThrowingRecoveryStatusDb extends LocalDb {
  _ThrowingRecoveryStatusDb() : super.forTesting(NativeDatabase.memory());

  bool failStatusWrites = false;
  int rejectedStatusWrites = 0;

  @override
  Future<bool> updateTranscriptionStatus(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required TranscriptionStatus status,
    required DateTime now,
    String? jobId,
    String? error,
  }) {
    if (failStatusWrites) {
      rejectedStatusWrites += 1;
      throw StateError('recovery status write failed');
    }
    return super.updateTranscriptionStatus(
      id,
      storageKey: storageKey,
      attempt: attempt,
      requestId: requestId,
      status: status,
      now: now,
      jobId: jobId,
      error: error,
    );
  }
}

class _FailOnceRecoveryStatusDb extends LocalDb {
  _FailOnceRecoveryStatusDb() : super.forTesting(NativeDatabase.memory());

  bool _failNextStatusWrite = true;

  @override
  Future<bool> updateTranscriptionStatus(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required TranscriptionStatus status,
    required DateTime now,
    String? jobId,
    String? error,
  }) {
    if (_failNextStatusWrite) {
      _failNextStatusWrite = false;
      throw StateError('first recovery status write failed');
    }
    return super.updateTranscriptionStatus(
      id,
      storageKey: storageKey,
      attempt: attempt,
      requestId: requestId,
      status: status,
      now: now,
      jobId: jobId,
      error: error,
    );
  }
}

class _ThrowingCompletionDb extends LocalDb {
  _ThrowingCompletionDb() : super.forTesting(NativeDatabase.memory());

  bool failTerminalPersistence = false;

  @override
  Future<bool> completeTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required String transcript,
    String? meetingNotes,
    required DateTime now,
    String? sidecarError,
  }) async {
    failTerminalPersistence = true;
    throw StateError('completion write failed');
  }

  @override
  Future<bool> updateTranscriptionStatus(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required TranscriptionStatus status,
    required DateTime now,
    String? jobId,
    String? error,
  }) {
    if (failTerminalPersistence && status == TranscriptionStatus.failed) {
      throw StateError('failure write failed');
    }
    return super.updateTranscriptionStatus(
      id,
      storageKey: storageKey,
      attempt: attempt,
      requestId: requestId,
      status: status,
      now: now,
      jobId: jobId,
      error: error,
    );
  }

  @override
  Future<DumpRow?> getDump(String id) {
    if (failTerminalPersistence) throw StateError('refresh read failed');
    return super.getDump(id);
  }
}

void main() {
  late Directory temp;
  late LocalDb db;
  late AudioStorage storage;
  late RecordingAccess access;
  late DefaultRecordingMutationCoordinator mutations;
  LocalDb? ownerDb;
  final owners = <DefaultRecordingMutationCoordinator>[];
  final backends = <FilesystemStorageBackend>[];
  Future<void> prepareStorage() async {
    if (identical(ownerDb, db)) return;
    ownerDb = db;
    final backend = FilesystemStorageBackend();
    backends.add(backend);
    mutations = DefaultRecordingMutationCoordinator(db: db);
    owners.add(mutations);
    await mutations.restoreFences(unsettled: await backend.unsettledUses());
    access =
        BoundRecordingAccess(db: db, backend: backend, mutations: mutations);
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tangent-server-q-');
    db = LocalDb.forTesting(NativeDatabase.memory());
    storage = AudioStorage.test(temp);
    await prepareStorage();
  });

  tearDown(() async {
    for (final backend in backends) {
      await backend.drain();
    }
    for (final owner in owners) {
      await owner.drain();
    }
    backends.clear();
    owners.clear();
    ownerDb = null;
    await db.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> seedRow(DumpRow row) async {
    await prepareStorage();
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
  }

  DumpRow row({
    String id = 'r1',
    String mode = 'brain_dump',
    String transcriptionStatus = 'not_transcribed',
    String? transcriptionRequestId,
    String? transcriptionJobId,
    int transcriptionAttempt = 0,
    DateTime? transcriptionCompletedAt,
    String? transcriptionError,
  }) {
    return DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: mode,
      durationSeconds: 5,
      title: 'Row $id',
      audioPath: storage.pathFor(id).path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: transcriptionStatus,
      transcriptionRequestId: transcriptionRequestId,
      transcriptionJobId: transcriptionJobId,
      transcriptionAttempt: transcriptionAttempt,
      transcriptionCompletedAt: transcriptionCompletedAt,
      transcriptionError: transcriptionError,
    );
  }

  test('persists a fresh retry identity before the first network call',
      () async {
    final now = DateTime.utc(2026, 9, 14, 12);
    await seedRow(
      row(
        transcriptionStatus: 'failed',
        transcriptionRequestId: 'request-old',
        transcriptionJobId: 'job-old',
        transcriptionAttempt: 3,
        transcriptionCompletedAt: DateTime.utc(2026, 9, 14, 11),
        transcriptionError: 'old failure',
      ),
    );
    late DumpRow observedAtFirstNetworkCall;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'retry transcript',
      onCreate: () async {
        observedAtFirstNetworkCall = (await db.getDump('r1'))!;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-new',
      now: () => now,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    expect(observedAtFirstNetworkCall.transcriptionStatus, 'uploading');
    expect(observedAtFirstNetworkCall.transcriptionRequestId, 'request-new');
    expect(observedAtFirstNetworkCall.transcriptionAttempt, 4);
    expect(observedAtFirstNetworkCall.transcriptionJobId, isNull);
    expect(observedAtFirstNetworkCall.transcriptionCompletedAt, isNull);
    expect(observedAtFirstNetworkCall.transcriptionError, isNull);
    expect(observedAtFirstNetworkCall.transcriptionStartedAt?.toUtc(), now);
  });

  test('persists queued running and completed state in network order',
      () async {
    final now = DateTime.utc(2026, 9, 14, 13);
    await seedRow(row());
    late DumpRow queuedRow;
    late DumpRow runningRow;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'durable transcript',
      onStreamStart: () async {
        queuedRow = (await db.getDump('r1'))!;
      },
      afterEvent: (status) async {
        if (status == 'running') runningRow = (await db.getDump('r1'))!;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-1',
      now: () => now,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final completed = (await db.getDump('r1'))!;
    expect(fake.calls, ['create', 'upload', 'enqueue', 'stream']);
    expect(queuedRow.transcriptionStatus, 'queued');
    expect(queuedRow.transcriptionJobId, 'job-r1');
    expect(runningRow.transcriptionStatus, 'running');
    expect(completed.transcriptionStatus, 'completed');
    expect(completed.transcriptionRequestId, 'request-1');
    expect(completed.transcriptionJobId, 'job-r1');
    expect(completed.transcriptionAttempt, 1);
    expect(completed.transcript, 'durable transcript');
    expect(completed.transcriptionCompletedAt, isNotNull);
  });

  test('dispose cancels the active stream and preserves its durable identity',
      () async {
    await seedRow(row());
    final streamStarted = Completer<void>();
    final streamCanceled = Completer<void>();
    final stream = StreamController<JobEvent>.broadcast(
      onCancel: streamCanceled.complete,
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onStreamStart: streamStarted.complete,
      streamForJob: (_) => stream.stream,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-active',
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) service.dispose();
    });
    addTearDown(stream.close);

    final operation = service.transcribeDump('r1');
    await streamStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    disposed = true;
    await streamCanceled.future.timeout(const Duration(milliseconds: 200));
    stream.add(
      const JobEvent('completed', {'transcript': 'must be ignored'}),
    );
    await operation.timeout(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final afterLateEvent = (await db.getDump('r1'))!;
    expect(
      afterLateEvent.transcriptionStatus,
      beforeDispose.transcriptionStatus,
    );
    expect(afterLateEvent.transcript, beforeDispose.transcript);
    expect(afterLateEvent.transcriptionError, beforeDispose.transcriptionError);
    expect(afterLateEvent.transcriptionRequestId, 'request-active');
    expect(afterLateEvent.transcriptionJobId, 'job-r1');
    expect(afterLateEvent.transcriptionAttempt, 1);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('dispose prevents a pending enqueue from starting a late stream',
      () async {
    await seedRow(row());
    final enqueueStarted = Completer<void>();
    final enqueueResult = Completer<TranscriptionJobSnapshot>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must not run',
      onEnqueue: (dumpId, requestId, model) {
        enqueueStarted.complete();
        return enqueueResult.future;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-pending-enqueue',
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) service.dispose();
    });

    final operation = service.transcribeDump('r1');
    await enqueueStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    disposed = true;
    enqueueResult.complete(
      const TranscriptionJobSnapshot(
        id: 'job-late-enqueue',
        requestId: 'request-pending-enqueue',
        dumpId: 'r1',
        status: 'queued',
        model: 'large-v3',
      ),
    );
    await operation.timeout(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final afterLateResponse = (await db.getDump('r1'))!;
    expect(fake.streamJobCalls, 0);
    expect(
      afterLateResponse.transcriptionStatus,
      beforeDispose.transcriptionStatus,
    );
    expect(afterLateResponse.transcriptionRequestId, 'request-pending-enqueue');
    expect(afterLateResponse.transcriptionJobId, isNull);
    expect(afterLateResponse.transcriptionAttempt, 1);
  });

  test('commits the winning completion before writing its sidecar', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'database first',
    );
    DumpRow? rowSeenBySidecarWriter;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-db-first',
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        rowSeenBySidecarWriter = (await db.getDump(id))!;
      },
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    expect(rowSeenBySidecarWriter?.transcriptionStatus, 'completed');
    expect(rowSeenBySidecarWriter?.transcript, 'database first');
    expect(rowSeenBySidecarWriter?.transcriptionRequestId, 'request-db-first');
  });

  test('holds the winning sidecar barrier until the write finishes', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(completedTranscript: 'barrier text');
    Object? concurrentStartError;
    Map<String, dynamic>? writtenMetadata;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-barrier',
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        writtenMetadata = metadata;
        try {
          await db.beginTranscriptionAttempt(
            id,
            storageKey: fileFixtureKey(id),
            requestId: 'request-concurrent',
            now: DateTime.utc(2026, 9, 14, 15),
          );
        } catch (error) {
          concurrentStartError = error;
        }
      },
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(concurrentStartError, isA<StateError>());
    expect(writtenMetadata?['transcript'], 'barrier text');
    expect(writtenMetadata?['transcriptionStatus'], 'completed');
    expect(writtenMetadata?['transcriptionError'], isNull);
    expect(saved.transcriptionError, isNull);
  });

  test('sidecar failure preserves completed DB state with a repair marker',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'safe in sqlite',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-sidecar-failure',
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        expect(id, 'r1');
        throw const AudioStorageException('disk unavailable');
      },
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcript, 'safe in sqlite');
    expect(saved.transcriptionError, startsWith('sidecar_sync_pending:'));
  });

  test('sidecar wait deadline releases the local FIFO', () async {
    await seedRow(row(id: 'r1'));
    await seedRow(row(id: 'r2'));
    final writerStarted = Completer<void>();
    final releaseWriter = Completer<void>();
    addTearDown(() {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'durable transcript',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${fake.enqueueCalls + 1}',
      sidecarWaitTimeout: const Duration(milliseconds: 10),
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        if (id != 'r1') return;
        writerStarted.complete();
        await releaseWriter.future;
      },
    );
    addTearDown(service.dispose);

    final first = service.transcribeDump('r1');
    final second = service.transcribeDump('r2');
    await writerStarted.future.timeout(const Duration(milliseconds: 200));
    await Future.wait([first, second])
        .timeout(const Duration(milliseconds: 300));

    var firstRow = (await db.getDump('r1'))!;
    final secondRow = (await db.getDump('r2'))!;
    expect(firstRow.transcriptionStatus, 'completed');
    expect(firstRow.transcriptionError, startsWith('sidecar_sync_pending:'));
    expect(secondRow.transcriptionStatus, 'completed');
    expect(secondRow.transcriptionError, isNull);
    expect(fake.createCalls, 2);
    expect(fake.uploadCalls, 2);
    expect(fake.enqueueCalls, 2);

    releaseWriter.complete();
    final repairDeadline =
        DateTime.now().add(const Duration(milliseconds: 200));
    while (true) {
      firstRow = (await db.getDump('r1'))!;
      if (firstRow.transcriptionError == null) break;
      if (DateTime.now().isAfter(repairDeadline)) {
        fail('late serialized sidecar completion did not clear its marker');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(firstRow.transcript, 'durable transcript');
  });

  test(
      'stale completion cannot overwrite or write a sidecar for a newer attempt',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'stale transcript',
      afterEvent: (status) async {
        if (status == 'running') {
          await db.updateTranscriptionStatus(
            'r1',
            storageKey: fileFixtureKey('r1'),
            attempt: 1,
            requestId: 'request-stale',
            status: TranscriptionStatus.failed,
            now: DateTime.utc(2026, 9, 14, 13, 59),
            error: 'attempt 1 superseded',
          );
          final newer = await db.beginTranscriptionAttempt(
            'r1',
            storageKey: fileFixtureKey('r1'),
            requestId: 'request-newer',
            now: DateTime.utc(2026, 9, 14, 14),
          );
          await db.updateTranscriptionStatus(
            'r1',
            storageKey: fileFixtureKey('r1'),
            attempt: newer.transcriptionAttempt,
            requestId: newer.transcriptionRequestId!,
            status: TranscriptionStatus.queued,
            now: DateTime.utc(2026, 9, 14, 14, 1),
            jobId: 'job-newer',
          );
          await db.completeTranscriptionAttempt(
            'r1',
            storageKey: fileFixtureKey('r1'),
            attempt: newer.transcriptionAttempt,
            requestId: newer.transcriptionRequestId!,
            transcript: 'newer transcript',
            now: DateTime.utc(2026, 9, 14, 14, 2),
          );
          final completedNewer = (await db.getDump('r1'))!;
          await storage.writeMetadata(
            'r1',
            dumpMetadata(completedNewer),
          );
        }
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-stale',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final current = (await db.getDump('r1'))!;
    final sidecar = jsonDecode(storage.metaPathFor('r1').readAsStringSync())
        as Map<String, dynamic>;
    expect(current.transcriptionStatus, 'completed');
    expect(current.transcriptionRequestId, 'request-newer');
    expect(current.transcriptionAttempt, 2);
    expect(current.transcript, 'newer transcript');
    expect(sidecar['transcriptionRequestId'], 'request-newer');
    expect(sidecar['transcript'], 'newer transcript');
  });

  test(
      'durable in-progress state rejects a duplicate start after reconstruction',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must not run',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-duplicate',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final current = (await db.getDump('r1'))!;
    expect(fake.calls, isEmpty);
    expect(current.transcriptionAttempt, 2);
    expect(current.transcriptionRequestId, 'request-existing');
    expect(current.transcriptionJobId, 'job-existing');
  });

  test('reattaches a running job without creating uploading or enqueueing',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'completed',
        model: 'large-v3',
        transcript: 'recovered transcript',
      ),
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.enqueueCalls, 0);
    expect(fake.getJobCalls, 1);
    expect(fake.getJobIds, ['job-existing']);
    expect(generatedIds, 0);
    expect((await db.getDump('r1'))!.transcript, 'recovered transcript');
  });

  test('completed snapshot with blank transcript becomes durable failed',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'completed',
        model: 'large-v3',
        transcript: '   ',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionStatus, 'failed');
    expect(recovered.transcriptionError, 'Server returned an empty transcript');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionAttempt, 2);
    expect(fake.streamJobCalls, 0);
    expect(
      (await db.dumpsNeedingTranscriptionRecovery()).map((row) => row.id),
      isNot(contains('r1')),
    );
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('persists a terminal failed snapshot without attaching a stream',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'failed',
        model: 'large-v3',
        error: 'worker crashed',
      ),
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();
    await Future<void>.delayed(Duration.zero);

    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionStatus, 'failed');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionError, 'worker crashed');
    expect(fake.streamJobCalls, 0);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('coalesces same-turn reconciliation calls before attaching streams',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final getStarted = Completer<void>();
    final releaseGet = Completer<void>();
    addTearDown(() {
      if (!releaseGet.isCompleted) releaseGet.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) async {
        if (!getStarted.isCompleted) getStarted.complete();
        await releaseGet.future;
        return const TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: 'running',
          model: 'large-v3',
        );
      },
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final first = service.reconcilePending();
    final second = service.reconcilePending();
    expect(identical(first, second), isTrue);
    await getStarted.future;
    await Future<void>.delayed(Duration.zero);
    releaseGet.complete();
    await Future.wait([first, second]);
    await Future<void>.delayed(Duration.zero);

    expect(fake.getJobCalls, 1);
    expect(fake.streamJobCalls, 1);
    expect(fake.enqueueCalls, 0);
  });

  test('a trigger after snapshot capture drains a later SQLite generation',
      () async {
    await db.close();
    db = _FirstSnapshotPausedRecoveryQueryDb();
    await seedRow(
      row(
        id: 'old-row',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-old',
        transcriptionJobId: 'job-old',
        transcriptionAttempt: 1,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => jobId == 'job-old'
          ? const TranscriptionJobSnapshot(
              id: 'job-old',
              requestId: 'request-old',
              dumpId: 'old-row',
              status: 'completed',
              model: 'large-v3',
              transcript: 'old snapshot recovered',
            )
          : const TranscriptionJobSnapshot(
              id: 'job-new',
              requestId: 'request-new',
              dumpId: 'new-row',
              status: 'completed',
              model: 'large-v3',
              transcript: 'new snapshot recovered',
            ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final firstGeneration = service.reconcilePending();
    final pausedDb = db as _FirstSnapshotPausedRecoveryQueryDb;
    await pausedDb.firstQueryCaptured.future;
    await seedRow(
      row(
        id: 'new-row',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-new',
        transcriptionJobId: 'job-new',
        transcriptionAttempt: 1,
      ),
    );
    final secondGeneration = service.reconcilePending();
    pausedDb.releaseFirstQuery.complete();

    await Future.wait([firstGeneration, secondGeneration]).timeout(
      const Duration(milliseconds: 500),
    );

    final oldRow = (await db.getDump('old-row'))!;
    final newRow = (await db.getDump('new-row'))!;
    expect(pausedDb.recoveryQueryCalls, 2);
    expect(fake.getJobIds, ['job-old', 'job-new']);
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.enqueueCalls, 0);
    expect(fake.streamJobCalls, 0);
    expect(oldRow.transcriptionStatus, 'completed');
    expect(oldRow.transcript, 'old snapshot recovered');
    expect(newRow.transcriptionStatus, 'completed');
    expect(newRow.transcript, 'new snapshot recovered');
    expect(newRow.transcriptionAttempt, 1);
    expect(newRow.transcriptionRequestId, 'request-new');
    expect(newRow.transcriptionJobId, 'job-new');
    expect(await storage.pathFor('new-row').readAsBytes(), [1, 2, 3]);
  });

  test('reconciliation skips a locally active dump and recovers other rows',
      () async {
    await seedRow(row(id: 'active'));
    await seedRow(
      row(
        id: 'recoverable',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-recoverable',
        transcriptionJobId: 'job-recoverable',
        transcriptionAttempt: 3,
      ),
    );
    final activeStream = StreamController<JobEvent>.broadcast();
    final activeStreamStarted = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onStreamStart: () {
        if (!activeStreamStarted.isCompleted) activeStreamStarted.complete();
      },
      onGetJob: (jobId) => jobId == 'job-recoverable'
          ? const TranscriptionJobSnapshot(
              id: 'job-recoverable',
              requestId: 'request-recoverable',
              dumpId: 'recoverable',
              status: 'completed',
              model: 'large-v3',
              transcript: 'recovered independently',
            )
          : const TranscriptionJobSnapshot(
              id: 'job-active',
              requestId: 'request-active',
              dumpId: 'active',
              status: 'running',
              model: 'large-v3',
            ),
      streamForJob: (_) => activeStream.stream,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-active',
    );
    addTearDown(service.dispose);
    addTearDown(activeStream.close);

    final operation = service.transcribeDump('active');
    await activeStreamStarted.future;
    final activeBeforeResume = (await db.getDump('active'))!;

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final activeAfterResume = (await db.getDump('active'))!;
    final recovered = (await db.getDump('recoverable'))!;
    expect(fake.enqueueCalls, 1);
    expect(fake.streamJobIds, ['job-active']);
    expect(fake.getJobIds, ['job-recoverable']);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(
      activeAfterResume.transcriptionRequestId,
      activeBeforeResume.transcriptionRequestId,
    );
    expect(
      activeAfterResume.transcriptionJobId,
      activeBeforeResume.transcriptionJobId,
    );
    expect(
      activeAfterResume.transcriptionAttempt,
      activeBeforeResume.transcriptionAttempt,
    );
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'recovered independently');

    activeStream.add(
      const JobEvent('completed', {'transcript': 'active completed once'}),
    );
    await operation.timeout(const Duration(milliseconds: 200));
  });

  test('recoverable local exit automatically hands ownership to reconciliation',
      () async {
    await seedRow(row(id: 'active'));
    final localStream = StreamController<JobEvent>.broadcast();
    final localStreamStarted = Completer<void>();
    final recoveryStreamStarted = Completer<void>();
    var streamCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-active',
        requestId: 'request-active',
        dumpId: 'active',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (jobId) {
        streamCalls += 1;
        if (streamCalls == 1) {
          localStreamStarted.complete();
          return localStream.stream;
        }
        recoveryStreamStarted.complete();
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('completed', {'transcript': 'recovered after local exit'}),
        ]);
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-active',
    );
    addTearDown(service.dispose);
    addTearDown(localStream.close);

    final operation = service.transcribeDump('active');
    await localStreamStarted.future;
    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    expect(fake.getJobCalls, 0);
    expect(fake.streamJobCalls, 1);

    localStream.add(
      const JobEvent('error', {'error': 'local observer disconnected'}),
    );
    await operation.timeout(const Duration(milliseconds: 200));
    await recoveryStreamStarted.future
        .timeout(const Duration(milliseconds: 200));

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('active'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('reconciliation did not adopt the recoverable local attempt');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
    expect(fake.getJobIds, ['job-active']);
    expect(fake.streamJobIds, ['job-active', 'job-active']);
    expect(recovered.transcriptionAttempt, 1);
    expect(recovered.transcriptionRequestId, 'request-active');
    expect(recovered.transcriptionJobId, 'job-active');
    expect(recovered.transcript, 'recovered after local exit');
    expect(await storage.pathFor('active').readAsBytes(), [1, 2, 3]);
  });

  test('queued local ownership wins a scan-to-attachment race', () async {
    await seedRow(row(id: 'blocker'));
    await seedRow(
      row(
        id: 'queued',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-queued',
        transcriptionJobId: 'job-queued',
        transcriptionAttempt: 2,
      ),
    );
    final blockerStream = StreamController<JobEvent>.broadcast();
    final recoveryStream = StreamController<JobEvent>.broadcast();
    final blockerStarted = Completer<void>();
    final getStarted = Completer<void>();
    final releaseGet = Completer<void>();
    addTearDown(() {
      if (!releaseGet.isCompleted) releaseGet.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onStreamStart: () {
        if (!blockerStarted.isCompleted) blockerStarted.complete();
      },
      onGetJob: (jobId) async {
        getStarted.complete();
        await releaseGet.future;
        return const TranscriptionJobSnapshot(
          id: 'job-queued',
          requestId: 'request-queued',
          dumpId: 'queued',
          status: 'running',
          model: 'large-v3',
        );
      },
      streamForJob: (jobId) =>
          jobId == 'job-blocker' ? blockerStream.stream : recoveryStream.stream,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-blocker',
    );
    addTearDown(service.dispose);
    addTearDown(blockerStream.close);
    addTearDown(recoveryStream.close);

    final blocker = service.transcribeDump('blocker');
    await blockerStarted.future;
    final scan = service.reconcilePending();
    await getStarted.future;

    final queued = service.transcribeDump('queued');
    expect(service.queuedDumpIds, ['queued']);
    releaseGet.complete();
    await scan.timeout(const Duration(milliseconds: 200));
    await Future<void>.delayed(Duration.zero);

    expect(fake.getJobIds, ['job-queued']);
    expect(fake.streamJobIds, ['job-blocker']);

    service.dispose();
    await Future.wait([blocker, queued]);
  });

  test(
      'terminal recovery prevents a queued duplicate from starting a fresh attempt',
      () async {
    await seedRow(row(id: 'blocker'));
    await seedRow(
      row(
        id: 'target',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-target',
        transcriptionJobId: 'job-target',
        transcriptionAttempt: 2,
      ),
    );
    final blockerStream = StreamController<JobEvent>.broadcast();
    final blockerStarted = Completer<void>();
    final targetGetStarted = Completer<void>();
    final releaseTargetGet = Completer<void>();
    addTearDown(() {
      if (!releaseTargetGet.isCompleted) releaseTargetGet.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'fresh attempt must not run',
      onGetJob: (jobId) async {
        targetGetStarted.complete();
        await releaseTargetGet.future;
        return const TranscriptionJobSnapshot(
          id: 'job-target',
          requestId: 'request-target',
          dumpId: 'target',
          status: 'completed',
          model: 'large-v3',
          transcript: 'recovered terminal transcript',
        );
      },
      streamForJob: (jobId) {
        if (jobId == 'job-blocker') {
          blockerStarted.complete();
          return blockerStream.stream;
        }
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('completed', {'transcript': 'fresh attempt must not run'}),
        ]);
      },
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);
    addTearDown(blockerStream.close);

    final blocker = service.transcribeDump('blocker');
    await blockerStarted.future;
    final scan = service.reconcilePending();
    await targetGetStarted.future;

    final queuedTarget = service.transcribeDump('target');
    expect(service.queuedDumpIds, ['target']);
    releaseTargetGet.complete();
    await scan.timeout(const Duration(milliseconds: 200));

    final recoveredBeforeQueueRelease = (await db.getDump('target'))!;
    expect(recoveredBeforeQueueRelease.transcriptionStatus, 'completed');
    expect(recoveredBeforeQueueRelease.transcriptionAttempt, 2);
    expect(
      recoveredBeforeQueueRelease.transcript,
      'recovered terminal transcript',
    );

    blockerStream.add(
      const JobEvent('completed', {'transcript': 'blocker complete'}),
    );
    await Future.wait([blocker, queuedTarget]).timeout(
      const Duration(milliseconds: 200),
    );

    final recovered = (await db.getDump('target'))!;
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
    expect(fake.getJobIds, ['job-target']);
    expect(generatedIds, 1);
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-target');
    expect(recovered.transcriptionJobId, 'job-target');
    expect(recovered.transcript, 'recovered terminal transcript');
    expect(await storage.pathFor('target').readAsBytes(), [1, 2, 3]);
  });

  test('recoverable recovery with a queued duplicate schedules another scan',
      () async {
    await seedRow(row(id: 'blocker'));
    await seedRow(
      row(
        id: 'target',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-target',
        transcriptionJobId: 'job-target',
        transcriptionAttempt: 2,
      ),
    );
    final blockerStream = StreamController<JobEvent>.broadcast();
    final blockerStarted = Completer<void>();
    final firstTargetGetStarted = Completer<void>();
    final releaseFirstTargetGet = Completer<void>();
    addTearDown(() {
      if (!releaseFirstTargetGet.isCompleted) releaseFirstTargetGet.complete();
    });
    final secondTargetGetStarted = Completer<void>();
    var targetGetCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'fresh attempt must not run',
      onGetJob: (jobId) async {
        targetGetCalls += 1;
        if (targetGetCalls == 1) {
          firstTargetGetStarted.complete();
          await releaseFirstTargetGet.future;
          throw TimeoutException('ambiguous recovery timeout');
        }
        secondTargetGetStarted.complete();
        return const TranscriptionJobSnapshot(
          id: 'job-target',
          requestId: 'request-target',
          dumpId: 'target',
          status: 'completed',
          model: 'large-v3',
          transcript: 'recovered after retry',
        );
      },
      streamForJob: (jobId) {
        if (jobId == 'job-blocker') {
          blockerStarted.complete();
          return blockerStream.stream;
        }
        return const Stream<JobEvent>.empty();
      },
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);
    addTearDown(blockerStream.close);

    final blocker = service.transcribeDump('blocker');
    await blockerStarted.future;
    final blockerRow = (await db.getDump('blocker'))!;
    expect(
      await db.completeTranscriptionAttempt(
        'blocker',
        storageKey: fileFixtureKey('blocker'),
        attempt: blockerRow.transcriptionAttempt,
        requestId: blockerRow.transcriptionRequestId!,
        transcript: 'terminalized test blocker',
        now: DateTime.utc(2026, 9, 15),
      ),
      isTrue,
    );
    final scan = service.reconcilePending();
    await firstTargetGetStarted.future;

    final queuedTarget = service.transcribeDump('target');
    releaseFirstTargetGet.complete();
    await scan.timeout(const Duration(milliseconds: 200));

    blockerStream.add(
      const JobEvent('completed', {'transcript': 'blocker complete'}),
    );
    await Future.wait([blocker, queuedTarget]).timeout(
      const Duration(milliseconds: 200),
    );
    await secondTargetGetStarted.future.timeout(
      const Duration(milliseconds: 200),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('target'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('recovery-only queue release did not schedule reconciliation');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(targetGetCalls, 2);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
    expect(generatedIds, 1);
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-target');
    expect(recovered.transcriptionJobId, 'job-target');
    expect(recovered.transcript, 'recovered after retry');
    expect(await storage.pathFor('target').readAsBytes(), [1, 2, 3]);
  });

  test(
      'cancelling a queued recovery owner immediately reconciles its durable row',
      () async {
    await seedRow(row(id: 'blocker'));
    await seedRow(
      row(
        id: 'target',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-target',
        transcriptionJobId: 'job-target',
        transcriptionAttempt: 2,
      ),
    );
    final blockerStream = StreamController<JobEvent>.broadcast();
    final blockerStarted = Completer<void>();
    final targetRecoveryStarted = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        targetRecoveryStarted.complete();
        return const TranscriptionJobSnapshot(
          id: 'job-target',
          requestId: 'request-target',
          dumpId: 'target',
          status: 'completed',
          model: 'large-v3',
          transcript: 'recovered after queued cancellation',
        );
      },
      streamForJob: (jobId) {
        if (jobId == 'job-blocker') {
          blockerStarted.complete();
          return blockerStream.stream;
        }
        return const Stream<JobEvent>.empty();
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-blocker',
    );
    addTearDown(service.dispose);
    addTearDown(blockerStream.close);

    final blocker = service.transcribeDump('blocker');
    await blockerStarted.future;
    final queuedTarget = service.transcribeDump('target');
    expect(service.queuedDumpIds, ['target']);

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    expect(fake.getJobCalls, 0);
    service.cancel('target');
    await queuedTarget.timeout(const Duration(milliseconds: 200));
    await targetRecoveryStarted.future.timeout(
      const Duration(milliseconds: 200),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('target'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('cancelled local ownership did not hand off to reconciliation');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(service.queuedDumpIds, isEmpty);
    expect(fake.getJobIds, ['job-target']);
    expect(fake.streamJobIds, ['job-blocker']);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-target');
    expect(recovered.transcriptionJobId, 'job-target');
    expect(recovered.transcript, 'recovered after queued cancellation');
    expect(await storage.pathFor('target').readAsBytes(), [1, 2, 3]);

    service.dispose();
    await blocker.timeout(const Duration(milliseconds: 200));
  });

  test('local handoff waits for an in-flight scan before adopting the job',
      () async {
    await seedRow(row(id: 'blocker'));
    await seedRow(
      row(
        id: 'queued',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-queued',
        transcriptionJobId: 'job-queued',
        transcriptionAttempt: 2,
      ),
    );
    await seedRow(
      row(
        id: 'scan-blocker',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-scan-blocker',
        transcriptionJobId: 'job-scan-blocker',
        transcriptionAttempt: 1,
      ),
    );
    final blockerStream = StreamController<JobEvent>.broadcast();
    final blockerStarted = Completer<void>();
    final targetGetStarted = Completer<void>();
    final releaseTargetGet = Completer<void>();
    addTearDown(() {
      if (!releaseTargetGet.isCompleted) releaseTargetGet.complete();
    });
    final scanBlockerGetStarted = Completer<void>();
    final releaseScanBlockerGet = Completer<void>();
    addTearDown(() {
      if (!releaseScanBlockerGet.isCompleted) releaseScanBlockerGet.complete();
    });
    final handoffGetStarted = Completer<void>();
    var targetGetCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) async {
        if (jobId == 'job-scan-blocker') {
          scanBlockerGetStarted.complete();
          await releaseScanBlockerGet.future;
          return const TranscriptionJobSnapshot(
            id: 'job-scan-blocker',
            requestId: 'request-scan-blocker',
            dumpId: 'scan-blocker',
            status: 'completed',
            model: 'large-v3',
            transcript: 'scan blocker complete',
          );
        }
        targetGetCalls += 1;
        if (targetGetCalls == 1) {
          targetGetStarted.complete();
          await releaseTargetGet.future;
        } else if (!handoffGetStarted.isCompleted) {
          handoffGetStarted.complete();
        }
        return const TranscriptionJobSnapshot(
          id: 'job-queued',
          requestId: 'request-queued',
          dumpId: 'queued',
          status: 'running',
          model: 'large-v3',
        );
      },
      streamForJob: (jobId) {
        if (jobId == 'job-blocker') {
          blockerStarted.complete();
          return blockerStream.stream;
        }
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('completed', {'transcript': 'handoff after scan'}),
        ]);
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-blocker',
    );
    addTearDown(service.dispose);
    addTearDown(blockerStream.close);

    final blocker = service.transcribeDump('blocker');
    await blockerStarted.future;
    final initialScan = service.reconcilePending();
    await Future.wait([targetGetStarted.future, scanBlockerGetStarted.future]);
    final queued = service.transcribeDump('queued');
    releaseTargetGet.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fake.streamJobIds, ['job-blocker']);

    blockerStream.add(
      const JobEvent('completed', {'transcript': 'blocker complete'}),
    );
    await Future.wait([blocker, queued]).timeout(
      const Duration(milliseconds: 200),
    );
    expect(handoffGetStarted.isCompleted, isFalse);

    releaseScanBlockerGet.complete();
    await initialScan.timeout(const Duration(milliseconds: 200));
    await handoffGetStarted.future.timeout(const Duration(milliseconds: 200));

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('queued'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('the local handoff was lost behind the in-flight scan');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(targetGetCalls, 2);
    expect(recovered.transcript, 'handoff after scan');
  });

  test('contains recovery query errors and allows a later scan', () async {
    await db.close();
    db = _FlakyRecoveryQueryDb();
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (_) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'completed',
        model: 'large-v3',
        transcript: 'recovered after query failure',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final flakyDb = db as _FlakyRecoveryQueryDb;
    final recovered = (await db.getDump('r1'))!;
    expect(flakyDb.recoveryQueryCalls, 2);
    expect(fake.getJobCalls, 1);
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'recovered after query failure');
  });

  test('dispose owns an initial scan whose recovery query returns late',
      () async {
    await db.close();
    db = _PausedRecoveryQueryDb();
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(completedTranscript: 'must not run');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    final pausedDb = db as _PausedRecoveryQueryDb;
    await pausedDb.queryStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    pausedDb.releaseQuery.complete();
    await scan.timeout(const Duration(milliseconds: 200));

    final afterDispose = (await db.getDump('r1'))!;
    expect(fake.calls, isEmpty);
    expect(afterDispose.transcriptionStatus, beforeDispose.transcriptionStatus);
    expect(
      afterDispose.transcriptionRequestId,
      beforeDispose.transcriptionRequestId,
    );
    expect(afterDispose.transcriptionJobId, beforeDispose.transcriptionJobId);
    expect(
      afterDispose.transcriptionAttempt,
      beforeDispose.transcriptionAttempt,
    );
    expect(afterDispose.transcriptionError, beforeDispose.transcriptionError);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('dispose owns a recovery row whose network result returns late',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final getStarted = Completer<void>();
    final releaseGet = Completer<void>();
    addTearDown(() {
      if (!releaseGet.isCompleted) releaseGet.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) async {
        getStarted.complete();
        await releaseGet.future;
        return const TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: 'failed',
          model: 'large-v3',
          error: 'must not be persisted',
        );
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    await getStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    releaseGet.complete();
    await scan.timeout(const Duration(milliseconds: 200));

    final afterDispose = (await db.getDump('r1'))!;
    expect(fake.getJobCalls, 1);
    expect(fake.streamJobCalls, 0);
    expect(afterDispose.transcriptionStatus, beforeDispose.transcriptionStatus);
    expect(afterDispose.transcript, beforeDispose.transcript);
    expect(afterDispose.transcriptionError, beforeDispose.transcriptionError);
    expect(afterDispose.transcriptionRequestId, 'request-existing');
    expect(afterDispose.transcriptionJobId, 'job-existing');
    expect(afterDispose.transcriptionAttempt, 2);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('dispose owns a recovery row whose network error returns late',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final enqueueStarted = Completer<void>();
    final releaseEnqueue = Completer<void>();
    addTearDown(() {
      if (!releaseEnqueue.isCompleted) releaseEnqueue.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (_, __, ___) async {
        enqueueStarted.complete();
        await releaseEnqueue.future;
        throw const ApiException(
          statusCode: 422,
          code: 'http_error',
          message: 'definitive late rejection',
        );
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    await enqueueStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    releaseEnqueue.complete();
    await scan.timeout(const Duration(milliseconds: 200));

    final afterDispose = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 1);
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.streamJobCalls, 0);
    expect(afterDispose.transcriptionStatus, beforeDispose.transcriptionStatus);
    expect(
      afterDispose.transcriptionRequestId,
      beforeDispose.transcriptionRequestId,
    );
    expect(afterDispose.transcriptionJobId, beforeDispose.transcriptionJobId);
    expect(
      afterDispose.transcriptionAttempt,
      beforeDispose.transcriptionAttempt,
    );
    expect(afterDispose.transcriptionError, beforeDispose.transcriptionError);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('secondary recovery status failures never escape reconciliation',
      () async {
    await db.close();
    db = _ThrowingRecoveryStatusDb();
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 4,
      ),
    );
    final beforeFailures = (await db.getDump('r1'))!;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (_, __, ___) => throw const ApiException(
        statusCode: 422,
        code: 'http_error',
        message: 'definitive recovery rejection',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    final throwingDb = db as _ThrowingRecoveryStatusDb;
    throwingDb.failStatusWrites = true;

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final uncaught = <Object>[];
    final zoned = runZonedGuarded<Future<void>>(
      () async {
        unawaited(service.reconcilePending());
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (throwingDb.rejectedStatusWrites < 3) {
          if (DateTime.now().isAfter(deadline)) {
            fail('fire-and-forget reconciliation did not finish');
          }
          await Future<void>.delayed(Duration.zero);
        }
        await Future<void>.delayed(Duration.zero);
      },
      (error, _) => uncaught.add(error),
    );
    if (zoned != null) await zoned;

    final afterFailures = (await db.getDump('r1'))!;
    expect(uncaught, isEmpty);
    expect(throwingDb.rejectedStatusWrites, 3);
    expect(fake.enqueueCalls, 3);
    expect(
      afterFailures.transcriptionStatus,
      beforeFailures.transcriptionStatus,
    );
    expect(
      afterFailures.transcriptionRequestId,
      beforeFailures.transcriptionRequestId,
    );
    expect(afterFailures.transcriptionJobId, beforeFailures.transcriptionJobId);
    expect(
      afterFailures.transcriptionAttempt,
      beforeFailures.transcriptionAttempt,
    );
    expect(afterFailures.transcriptionError, beforeFailures.transcriptionError);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('preserves the underlying persistence failure in recovery diagnostics',
      () async {
    await db.close();
    db = _FailOnceRecoveryStatusDb();
    await seedRow(
      row(
        transcriptionStatus: 'queued',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 4,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (_) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionStatus, 'queued');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(
      recovered.transcriptionError,
      contains('first recovery status write failed'),
    );
  });

  test('writes recovered terminal output to the sidecar before clearing marker',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    Map<String, dynamic>? writtenMetadata;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'completed',
        model: 'large-v3',
        transcript: 'recovered transcript',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        expect(id, 'r1');
        writtenMetadata = metadata;
      },
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(writtenMetadata?['transcript'], 'recovered transcript');
    expect(writtenMetadata?['transcriptionError'], isNull);
    expect(recovered.transcriptionError, isNull);
  });

  test('attaches a nonterminal persisted job without upload or enqueue',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stream = StreamController<JobEvent>.broadcast();
    final streamStarted = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (jobId) {
        streamStarted.complete();
        return stream.stream;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(stream.close);

    await service.reconcilePending();
    await streamStarted.future.timeout(const Duration(milliseconds: 200));

    expect(fake.getJobCalls, 1);
    expect(fake.streamJobIds, ['job-existing']);
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.enqueueCalls, 0);
  });

  test('persists a running snapshot before reattaching its stream', () async {
    await seedRow(
      row(
        transcriptionStatus: 'queued',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stream = StreamController<JobEvent>.broadcast();
    final streamStarted = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (_) {
        streamStarted.complete();
        return stream.stream;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(stream.close);

    await service.reconcilePending();
    await streamStarted.future.timeout(const Duration(milliseconds: 200));

    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionStatus, 'running');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionAttempt, 2);
  });

  test('persists running progress from a reattached stream', () async {
    await seedRow(
      row(
        transcriptionStatus: 'queued',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stream = StreamController<JobEvent>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (_) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'queued',
        model: 'large-v3',
      ),
      streamForJob: (_) => stream.stream,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(stream.close);

    await service.reconcilePending();
    stream.add(const JobEvent('running', {}));

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'running') break;
      if (DateTime.now().isAfter(deadline)) {
        fail('reattached stream did not persist running progress');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionAttempt, 2);
  });

  test('dispose cancels a reattached stream and ignores late completion',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final streamStarted = Completer<void>();
    final streamCanceled = Completer<void>();
    final stream = StreamController<JobEvent>.broadcast(
      onCancel: streamCanceled.complete,
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      onStreamStart: streamStarted.complete,
      streamForJob: (_) => stream.stream,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) service.dispose();
    });
    addTearDown(stream.close);

    await service.reconcilePending();
    await streamStarted.future;
    final beforeDispose = (await db.getDump('r1'))!;

    service.dispose();
    disposed = true;
    await streamCanceled.future.timeout(const Duration(milliseconds: 200));
    stream.add(
      const JobEvent('completed', {'transcript': 'must be ignored'}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final afterLateEvent = (await db.getDump('r1'))!;
    expect(
      afterLateEvent.transcriptionStatus,
      beforeDispose.transcriptionStatus,
    );
    expect(afterLateEvent.transcript, beforeDispose.transcript);
    expect(afterLateEvent.transcriptionError, beforeDispose.transcriptionError);
    expect(afterLateEvent.transcriptionRequestId, 'request-existing');
    expect(afterLateEvent.transcriptionJobId, 'job-existing');
    expect(afterLateEvent.transcriptionAttempt, 2);
    expect(storage.metaPathFor('r1').existsSync(), isFalse);
  });

  test('persists completion received from a reattached job stream', () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stream = StreamController<JobEvent>.broadcast();
    final streamStarted = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (jobId) {
        streamStarted.complete();
        return stream.stream;
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(stream.close);

    await service.reconcilePending();
    await streamStarted.future;
    stream.add(
      const JobEvent('completed', {'transcript': 'stream recovery'}),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'completed') break;
      if (DateTime.now().isAfter(deadline)) {
        fail('reattached stream did not persist completion');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(recovered.transcript, 'stream recovery');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('blank completion from a reattached stream becomes durable failed',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (_) => Stream<JobEvent>.fromIterable(const [
        JobEvent('completed', {'transcript': '  '}),
      ]),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'failed') break;
      if (DateTime.now().isAfter(deadline)) {
        fail('blank stream completion did not persist durable failure');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(recovered.transcriptionError, 'Server returned an empty transcript');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionAttempt, 2);
    expect(
      (await db.dumpsNeedingTranscriptionRecovery()).map((row) => row.id),
      isNot(contains('r1')),
    );
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('stores a reattached stream connection error without losing identity',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
      streamForJob: (_) => Stream<JobEvent>.fromIterable(const [
        JobEvent('error', {'error': 'stream disconnected'}),
      ]),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionError != null) break;
      if (DateTime.now().isAfter(deadline)) {
        fail('reattached stream error was not persisted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(recovered.transcriptionStatus, 'running');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionError, startsWith('reconciliation_pending:'));
    expect(recovered.transcriptionError, contains('stream disconnected'));
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('ordinary recoverable reattachment exit starts one recovery scan',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    var getCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        getCalls += 1;
        return TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: getCalls == 1 ? 'running' : 'completed',
          model: 'large-v3',
          transcript: getCalls == 1 ? null : 'recovered after watcher exit',
        );
      },
      streamForJob: (_) => Stream<JobEvent>.fromIterable(const [
        JobEvent('error', {'error': 'stream disconnected'}),
      ]),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final deadline = DateTime.now().add(const Duration(milliseconds: 200));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('ordinary recoverable reattachment exit was not reconciled');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(fake.getJobIds, ['job-existing', 'job-existing']);
    expect(fake.enqueueCalls, 0);
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcript, 'recovered after watcher exit');
  });

  test('recovery timeout re-arms backoff and ignores its late result',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final lateSnapshot = Completer<TranscriptionJobSnapshot>();
    var getCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        getCalls += 1;
        if (getCalls == 2) return lateSnapshot.future;
        return TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: getCalls == 1 ? 'running' : 'completed',
          model: 'large-v3',
          transcript: getCalls == 1 ? null : 'eventually recovered',
        );
      },
      streamForJob: (_) => Stream<JobEvent>.fromIterable(const [
        JobEvent('error', {'error': 'observer disconnected'}),
      ]),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRequestTimeout: const Duration(milliseconds: 10),
      recoveryRetryBaseDelay: const Duration(milliseconds: 5),
      recoveryRetryMaxDelay: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final deadline = DateTime.now().add(const Duration(milliseconds: 300));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (getCalls == 3 &&
          recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('timed-out recovery did not re-arm a later retry');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    lateSnapshot.complete(
      const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    recovered = (await db.getDump('r1'))!;
    expect(getCalls, 3);
    expect(fake.enqueueCalls, 0);
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'eventually recovered');
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
  });

  test('terminal recovery resets retry backoff for a later attempt', () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 1,
      ),
    );
    var getCalls = 0;
    var streamCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        getCalls += 1;
        return TranscriptionJobSnapshot(
          id: getCalls < 3 ? 'job-existing' : 'job-new',
          requestId: getCalls < 3 ? 'request-existing' : 'request-new',
          dumpId: 'r1',
          status: getCalls == 1 ? 'running' : 'completed',
          model: 'large-v3',
          transcript: getCalls == 2
              ? 'first recovered transcript'
              : getCalls == 3
                  ? 'second recovered transcript'
                  : null,
        );
      },
      onEnqueue: (dumpId, requestId, model) => TranscriptionJobSnapshot(
        id: 'job-new',
        requestId: requestId,
        dumpId: dumpId,
        status: 'queued',
        model: model,
      ),
      streamForJob: (jobId) {
        streamCalls += 1;
        if (streamCalls == 1) {
          return Stream<JobEvent>.fromIterable(const [
            JobEvent('error', {'error': 'first observer failed'}),
          ]);
        }
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('queued', {}),
          JobEvent('running', {}),
          JobEvent('timeout', {'message': 'second observer failed'}),
        ]);
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-new',
      recoveryRetryBaseDelay: const Duration(seconds: 1),
      recoveryRetryMaxDelay: const Duration(seconds: 1),
    );
    addTearDown(service.dispose);

    await service.reconcilePending();
    final firstDeadline = DateTime.now().add(const Duration(milliseconds: 200));
    while (true) {
      final recovered = (await db.getDump('r1'))!;
      if (recovered.transcript == 'first recovered transcript' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(firstDeadline)) {
        fail('first recovery episode did not complete');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    await service.transcribeDump('r1');
    final secondDeadline =
        DateTime.now().add(const Duration(milliseconds: 200));
    while (true) {
      final recovered = (await db.getDump('r1'))!;
      if (recovered.transcript == 'second recovered transcript' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(secondDeadline)) {
        fail('later attempt inherited stale retry backoff');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(getCalls, 3);
    expect(streamCalls, 2);
    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionAttempt, 2);
    expect(recovered.transcriptionRequestId, 'request-new');
    expect(recovered.transcriptionJobId, 'job-new');
  });

  test('dispose cancels a pending delayed recovery retry', () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 1,
      ),
    );
    var getCalls = 0;
    var streamCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        getCalls += 1;
        return const TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: 'running',
          model: 'large-v3',
        );
      },
      streamForJob: (jobId) {
        streamCalls += 1;
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('error', {'error': 'observer failed'}),
        ]);
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRetryBaseDelay: const Duration(milliseconds: 100),
      recoveryRetryMaxDelay: const Duration(milliseconds: 100),
    );

    await service.reconcilePending();
    final armedDeadline = DateTime.now().add(const Duration(milliseconds: 200));
    while (streamCalls < 2) {
      if (DateTime.now().isAfter(armedDeadline)) {
        fail('delayed retry was not armed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(getCalls, 2);
    expect(streamCalls, 2);
  });

  test('a finishing reattachment hands a suppressed scan to a new watcher',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final firstStream = StreamController<JobEvent>.broadcast();
    final firstStreamStarted = Completer<void>();
    final handoffGetStarted = Completer<void>();
    final releaseHandoffGet = Completer<void>();
    addTearDown(() {
      if (!releaseHandoffGet.isCompleted) releaseHandoffGet.complete();
    });
    var getCalls = 0;
    var streamCalls = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) async {
        getCalls += 1;
        if (getCalls == 3) {
          handoffGetStarted.complete();
          await releaseHandoffGet.future;
        }
        return const TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: 'running',
          model: 'large-v3',
        );
      },
      streamForJob: (_) {
        streamCalls += 1;
        if (streamCalls == 1) {
          firstStreamStarted.complete();
          return firstStream.stream;
        }
        return Stream<JobEvent>.fromIterable(const [
          JobEvent('completed', {'transcript': 'replacement watcher'}),
        ]);
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(firstStream.close);

    await service.reconcilePending();
    await firstStreamStarted.future.timeout(const Duration(milliseconds: 200));
    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    expect(getCalls, 2);
    expect(streamCalls, 1);

    firstStream.add(
      const JobEvent('error', {'error': 'first watcher disconnected'}),
    );
    await handoffGetStarted.future.timeout(const Duration(milliseconds: 200));
    final disconnected = (await db.getDump('r1'))!;
    expect(
      disconnected.transcriptionError,
      contains('first watcher disconnected'),
    );
    releaseHandoffGet.complete();

    final completionDeadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(completionDeadline)) {
        fail('the suppressed scan was lost when its watcher finished');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(getCalls, 3);
    expect(streamCalls, 2);
    expect(recovered.transcript, 'replacement watcher');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    expect(recovered.transcriptionAttempt, 2);
  });

  test('does not let one running stream block another row completion',
      () async {
    await seedRow(
      row(
        id: 'r1',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-1',
        transcriptionJobId: 'job-1',
        transcriptionAttempt: 1,
      ),
    );
    await seedRow(
      row(
        id: 'r2',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-2',
        transcriptionJobId: 'job-2',
        transcriptionAttempt: 1,
      ),
    );
    final firstStream = StreamController<JobEvent>.broadcast();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => jobId == 'job-1'
          ? const TranscriptionJobSnapshot(
              id: 'job-1',
              requestId: 'request-1',
              dumpId: 'r1',
              status: 'running',
              model: 'large-v3',
            )
          : const TranscriptionJobSnapshot(
              id: 'job-2',
              requestId: 'request-2',
              dumpId: 'r2',
              status: 'completed',
              model: 'large-v3',
              transcript: 'row two completed',
            ),
      streamForJob: (jobId) => jobId == 'job-1'
          ? firstStream.stream
          : const Stream<JobEvent>.empty(),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);
    addTearDown(firstStream.close);

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final second = (await db.getDump('r2'))!;
    expect(second.transcriptionStatus, 'completed');
    expect(second.transcript, 'row two completed');
    expect(fake.streamJobIds, isNot(contains('job-2')));
  });

  test('starts initial job resolutions independently', () async {
    await seedRow(
      row(
        id: 'r1',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-1',
        transcriptionJobId: 'job-1',
        transcriptionAttempt: 1,
      ).copyWith(
        transcriptionStartedAt: Value(DateTime.utc(2026, 9, 14, 1)),
      ),
    );
    await seedRow(
      row(
        id: 'r2',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-2',
        transcriptionJobId: 'job-2',
        transcriptionAttempt: 1,
      ).copyWith(
        transcriptionStartedAt: Value(DateTime.utc(2026, 9, 14, 2)),
      ),
    );
    final firstGetStarted = Completer<void>();
    final releaseFirstGet = Completer<void>();
    addTearDown(() {
      if (!releaseFirstGet.isCompleted) releaseFirstGet.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) async {
        if (jobId == 'job-1') {
          firstGetStarted.complete();
          await releaseFirstGet.future;
          return const TranscriptionJobSnapshot(
            id: 'job-1',
            requestId: 'request-1',
            dumpId: 'r1',
            status: 'running',
            model: 'large-v3',
          );
        }
        return const TranscriptionJobSnapshot(
          id: 'job-2',
          requestId: 'request-2',
          dumpId: 'r2',
          status: 'completed',
          model: 'large-v3',
          transcript: 'row two completed',
        );
      },
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    await firstGetStarted.future;
    try {
      await (() async {
        while ((await db.getDump('r2'))!.transcriptionStatus != 'completed') {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      })()
          .timeout(const Duration(milliseconds: 200));
    } finally {
      releaseFirstGet.complete();
      await scan;
    }

    final second = (await db.getDump('r2'))!;
    expect(second.transcript, 'row two completed');
    expect(fake.getJobIds, containsAll(['job-1', 'job-2']));
  });

  test('bounds getJob recovery and permits a fresh reconciliation scan',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stalledGet = Completer<TranscriptionJobSnapshot>();
    var getAttempt = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        getAttempt += 1;
        if (getAttempt == 1) return stalledGet.future;
        return const TranscriptionJobSnapshot(
          id: 'job-existing',
          requestId: 'request-existing',
          dumpId: 'r1',
          status: 'completed',
          model: 'large-v3',
          transcript: 'completed on fresh scan',
        );
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRequestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(service.dispose);

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final timedOut = (await db.getDump('r1'))!;
    expect(timedOut.transcriptionStatus, 'running');
    expect(timedOut.transcriptionRequestId, 'request-existing');
    expect(timedOut.transcriptionJobId, 'job-existing');
    expect(timedOut.transcriptionAttempt, 2);
    expect(timedOut.transcriptionError, startsWith('reconciliation_pending:'));

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));

    final recovered = (await db.getDump('r1'))!;
    expect(fake.getJobCalls, 2);
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'completed on fresh scan');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-existing');
    stalledGet.complete(
      const TranscriptionJobSnapshot(
        id: 'job-existing',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'running',
        model: 'large-v3',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('timed-out enqueue stays recoverable with the same request identity',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stalledEnqueue = Completer<TranscriptionJobSnapshot>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (_, __, ___) => stalledEnqueue.future,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRequestTimeout: const Duration(milliseconds: 20),
      recoveryRetryBaseDelay: const Duration(seconds: 5),
      recoveryRetryMaxDelay: const Duration(seconds: 5),
    );
    addTearDown(service.dispose);

    await service.reconcilePending().timeout(const Duration(milliseconds: 200));
    final replayDeadline =
        DateTime.now().add(const Duration(milliseconds: 200));
    while (fake.enqueueCalls < 2) {
      if (DateTime.now().isAfter(replayDeadline)) {
        fail('timed-out enqueue did not replay its durable request ID');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    var timedOut = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 2);
    expect(timedOut.transcriptionStatus, 'uploading');
    expect(timedOut.transcriptionRequestId, 'request-existing');
    expect(timedOut.transcriptionJobId, isNull);
    expect(timedOut.transcriptionAttempt, 2);
    expect(timedOut.transcriptionError, startsWith('reconciliation_pending:'));

    service.dispose();
    stalledEnqueue.complete(
      const TranscriptionJobSnapshot(
        id: 'late-job',
        requestId: 'request-existing',
        dumpId: 'r1',
        status: 'queued',
        model: 'large-v3',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    timedOut = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 2);
    expect(timedOut.transcriptionStatus, 'uploading');
    expect(timedOut.transcriptionJobId, isNull);
  });

  test('bounds metadata creation during recovery', () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stalledCreate = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onCreate: () => stalledCreate.future,
      onEnqueue: (_, __, ___) => throw const ApiException(
        statusCode: 404,
        code: 'http_error',
        message: "Dump 'r1' not found",
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRequestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    try {
      await scan.timeout(const Duration(milliseconds: 200));
    } finally {
      stalledCreate.complete();
      await scan;
    }

    final timedOut = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 1);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 0);
    expect(timedOut.transcriptionStatus, 'uploading');
    expect(timedOut.transcriptionRequestId, 'request-existing');
    expect(timedOut.transcriptionJobId, isNull);
    expect(timedOut.transcriptionAttempt, 2);
    expect(timedOut.transcriptionError, startsWith('reconciliation_pending:'));
  });

  test('bounds audio upload during recovery', () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final stalledUpload = Completer<void>();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onUpload: () => stalledUpload.future,
      onEnqueue: (_, __, ___) => throw const ApiException(
        statusCode: 422,
        code: 'missing_audio',
        message: "No audio file uploaded for dump 'r1'. "
            'POST the audio to /v1/dumps/{id}/audio first.',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      recoveryRequestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(service.dispose);

    final scan = service.reconcilePending();
    try {
      await scan.timeout(const Duration(milliseconds: 200));
    } finally {
      stalledUpload.complete();
      await scan;
    }

    final timedOut = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 1);
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 1);
    expect(timedOut.transcriptionStatus, 'uploading');
    expect(timedOut.transcriptionRequestId, 'request-existing');
    expect(timedOut.transcriptionJobId, isNull);
    expect(timedOut.transcriptionAttempt, 2);
    expect(timedOut.transcriptionError, startsWith('reconciliation_pending:'));
  });

  test('recovery request timeout does not shorten normal transcription',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onCreate: () => Future<void>.delayed(const Duration(milliseconds: 10)),
      onUpload: () => Future<void>.delayed(const Duration(milliseconds: 10)),
      onEnqueue: (dumpId, requestId, model) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return TranscriptionJobSnapshot(
          id: 'job-normal',
          requestId: requestId,
          dumpId: dumpId,
          status: 'queued',
          model: model,
        );
      },
      streamForJob: (_) => Stream<JobEvent>.fromFuture(
        Future<JobEvent>.delayed(
          const Duration(milliseconds: 10),
          () => const JobEvent(
            'completed',
            {'transcript': 'normal transcription completed'},
          ),
        ),
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-normal',
      recoveryRequestTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(service.dispose);

    await service
        .transcribeDump('r1')
        .timeout(const Duration(milliseconds: 500));

    final completed = (await db.getDump('r1'))!;
    expect(completed.transcriptionStatus, 'completed');
    expect(completed.transcript, 'normal transcription completed');
    expect(completed.transcriptionJobId, 'job-normal');
  });

  test('repairs a pending completed sidecar from the committed row', () async {
    await seedRow(
      row(
        transcriptionStatus: 'completed',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
        transcriptionCompletedAt: DateTime.utc(2026, 9, 14, 15),
        transcriptionError: 'sidecar_sync_pending: disk unavailable',
      ).copyWith(transcript: const Value('committed transcript')),
    );
    Map<String, dynamic>? writtenMetadata;
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        expect(id, 'r1');
        writtenMetadata = metadata;
      },
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final repaired = (await db.getDump('r1'))!;
    expect(fake.calls, isEmpty);
    expect(writtenMetadata?['transcript'], 'committed transcript');
    expect(writtenMetadata?['transcriptionStatus'], 'completed');
    expect(writtenMetadata?['transcriptionError'], isNull);
    expect(repaired.transcriptionError, isNull);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('sidecar wait deadline releases reconciliation generations', () async {
    await seedRow(
      row(
        transcriptionStatus: 'completed',
        transcriptionRequestId: 'request-existing',
        transcriptionJobId: 'job-existing',
        transcriptionAttempt: 2,
        transcriptionCompletedAt: DateTime.utc(2026, 9, 14, 15),
        transcriptionError: 'sidecar_sync_pending: write pending',
      ).copyWith(transcript: const Value('committed transcript')),
    );
    final writerStarted = Completer<void>();
    final releaseWriter = Completer<void>();
    addTearDown(() {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
    });
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => TranscriptionJobSnapshot(
        id: jobId,
        requestId: 'request-r2',
        dumpId: 'r2',
        status: 'completed',
        model: 'large-v3',
        transcript: 'second row recovered',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      sidecarWaitTimeout: const Duration(milliseconds: 10),
      metadataWriter: (binding, metadata) async {
        final id = binding.key.dumpId;
        if (id != 'r1') return;
        writerStarted.complete();
        await releaseWriter.future;
      },
    );
    addTearDown(service.dispose);

    final firstScan = service.reconcilePending();
    await writerStarted.future.timeout(const Duration(milliseconds: 200));
    await firstScan.timeout(const Duration(milliseconds: 300));

    await seedRow(
      row(
        id: 'r2',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-r2',
        transcriptionJobId: 'job-r2',
        transcriptionAttempt: 1,
      ),
    );
    await service.reconcilePending().timeout(const Duration(milliseconds: 300));

    final secondRow = (await db.getDump('r2'))!;
    expect(fake.getJobIds, ['job-r2']);
    expect(secondRow.transcriptionStatus, 'completed');
    expect(secondRow.transcript, 'second row recovered');
    expect(secondRow.transcriptionError, isNull);

    releaseWriter.complete();
    final repairDeadline =
        DateTime.now().add(const Duration(milliseconds: 200));
    while (true) {
      final firstRow = (await db.getDump('r1'))!;
      if (firstRow.transcriptionError == null) break;
      if (DateTime.now().isAfter(repairDeadline)) {
        fail('late serialized repair did not clear its marker');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });

  test('replays a persisted request ID and stores its returned job ID',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (dumpId, requestId, model) => TranscriptionJobSnapshot(
        id: 'job-recovered',
        requestId: requestId,
        dumpId: dumpId,
        status: 'queued',
        model: model,
      ),
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(fake.enqueueCalls, 1);
    expect(fake.enqueueRequestIds, ['request-existing']);
    expect(recovered.transcriptionJobId, 'job-recovered');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionAttempt, 2);
    expect(generatedIds, 0);
  });

  test('persists a terminal completion returned by request ID replay',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (dumpId, requestId, model) => TranscriptionJobSnapshot(
        id: 'job-recovered',
        requestId: requestId,
        dumpId: dumpId,
        status: 'completed',
        model: model,
        transcript: 'already completed',
      ),
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'already completed');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, 'job-recovered');
    expect(fake.streamJobCalls, 0);
  });

  test(
      'repairs missing metadata then audio in one scan with the same request ID',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    var enqueueAttempt = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (dumpId, requestId, model) {
        enqueueAttempt += 1;
        switch (enqueueAttempt) {
          case 1:
            throw const ApiException(
              statusCode: 404,
              code: 'http_error',
              message: "Dump 'r1' not found",
            );
          case 2:
            throw const ApiException(
              statusCode: 422,
              code: 'missing_audio',
              message: "No audio file uploaded for dump 'r1'. "
                  'POST the audio to /v1/dumps/{id}/audio first.',
            );
        }
        return TranscriptionJobSnapshot(
          id: 'job-after-repair',
          requestId: requestId,
          dumpId: dumpId,
          status: 'queued',
          model: model,
        );
      },
      streamForJob: (_) => Stream<JobEvent>.fromIterable(const [
        JobEvent('completed', {'transcript': 'recovered after repair'}),
      ]),
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('r1'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('one-scan repair did not persist completion');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(fake.calls, [
      'enqueue',
      'create',
      'enqueue',
      'upload',
      'enqueue',
      'stream',
    ]);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.uploadedAudioBytes, [
      [1, 2, 3],
    ]);
    expect(fake.enqueueRequestIds, [
      'request-existing',
      'request-existing',
      'request-existing',
    ]);
    expect(recovered.transcriptionStatus, 'completed');
    expect(recovered.transcript, 'recovered after repair');
    expect(recovered.transcriptionJobId, 'job-after-repair');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionAttempt, 2);
    expect(generatedIds, 0);
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
  });

  test('reuploads missing server audio before replaying the same request ID',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    var enqueueAttempt = 0;
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (dumpId, requestId, model) {
        enqueueAttempt += 1;
        if (enqueueAttempt == 1) {
          throw const ApiException(
            statusCode: 422,
            code: 'missing_audio',
            message: "No audio file uploaded for dump 'r1'. "
                'POST the audio to /v1/dumps/{id}/audio first.',
          );
        }
        return TranscriptionJobSnapshot(
          id: 'job-after-audio',
          requestId: requestId,
          dumpId: dumpId,
          status: 'queued',
          model: model,
        );
      },
      streamForJob: (_) => const Stream<JobEvent>.empty(),
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(fake.calls.take(3), ['enqueue', 'upload', 'enqueue']);
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueRequestIds, [
      'request-existing',
      'request-existing',
    ]);
    expect(recovered.transcriptionJobId, 'job-after-audio');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(generatedIds, 0);
  });

  test('marks a missing local audio read as a terminal recovery failure',
      () async {
    await seedRow(
      row(
        transcriptionStatus: 'uploading',
        transcriptionRequestId: 'request-existing',
        transcriptionAttempt: 2,
      ),
    );
    storage.pathFor('r1').deleteSync();
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (_, __, ___) => throw const ApiException(
        statusCode: 422,
        code: 'missing_audio',
        message: "No audio file uploaded for dump 'r1'. "
            'POST the audio to /v1/dumps/{id}/audio first.',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final recovered = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 1);
    expect(fake.uploadCalls, 0);
    expect(recovered.transcriptionStatus, 'failed');
    expect(recovered.transcriptionRequestId, 'request-existing');
    expect(recovered.transcriptionJobId, isNull);
    expect(recovered.transcriptionAttempt, 2);
    expect(
      recovered.transcriptionError,
      contains('Failed to read durable audio'),
    );
  });

  test('reconciliation classifies enqueue outcomes before persisting state',
      () async {
    for (final (id, requestId) in [
      ('generic-422', 'request-generic'),
      ('conflict-409', 'request-conflict'),
      ('ambiguous-timeout', 'request-ambiguous'),
    ]) {
      await seedRow(
        row(
          id: id,
          transcriptionStatus: 'uploading',
          transcriptionRequestId: requestId,
          transcriptionAttempt: 4,
        ),
      );
    }
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (dumpId, requestId, model) {
        return switch (dumpId) {
          'generic-422' => throw const ApiException(
              statusCode: 422,
              code: 'http_error',
              message: 'HTTP 422',
            ),
          'conflict-409' => throw const ApiException(
              statusCode: 409,
              code: 'request_id_conflict',
              message: 'request_id conflict',
            ),
          _ => throw TimeoutException('enqueue response lost'),
        };
      },
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'unexpected-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final generic = (await db.getDump('generic-422'))!;
    final conflict = (await db.getDump('conflict-409'))!;
    final ambiguous = (await db.getDump('ambiguous-timeout'))!;
    expect(generic.transcriptionStatus, 'failed');
    expect(generic.transcriptionRequestId, 'request-generic');
    expect(generic.transcriptionAttempt, 4);
    expect(generic.transcriptionError, contains('HTTP 422'));
    expect(conflict.transcriptionStatus, 'failed');
    expect(conflict.transcriptionRequestId, 'request-conflict');
    expect(conflict.transcriptionAttempt, 4);
    expect(conflict.transcriptionError, contains('request_id_conflict'));
    expect(ambiguous.transcriptionStatus, 'uploading');
    expect(ambiguous.transcriptionRequestId, 'request-ambiguous');
    expect(ambiguous.transcriptionAttempt, 4);
    expect(ambiguous.transcriptionJobId, isNull);
    expect(
      ambiguous.transcriptionError,
      startsWith('reconciliation_pending:'),
    );
    expect(
      (await db.dumpsNeedingTranscriptionRecovery()).map((row) => row.id),
      ['ambiguous-timeout'],
    );
    expect(fake.createCalls, 0);
    expect(fake.uploadCalls, 0);
    expect(generatedIds, 0);
    for (final id in ['generic-422', 'conflict-409', 'ambiguous-timeout']) {
      expect(await storage.pathFor(id).readAsBytes(), [1, 2, 3]);
    }
  });

  test('recovery auth failures preserve existing job identity', () async {
    for (final statusCode in [401, 403]) {
      await seedRow(
        row(
          id: 'auth-$statusCode',
          transcriptionStatus: 'running',
          transcriptionRequestId: 'request-$statusCode',
          transcriptionJobId: 'job-$statusCode',
          transcriptionAttempt: 3,
        ),
      );
    }
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) => throw ApiException(
        statusCode: int.parse(jobId.substring('job-'.length)),
        code: 'http_error',
        message: 'credentials rejected',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    for (final statusCode in [401, 403]) {
      final recovered = (await db.getDump('auth-$statusCode'))!;
      expect(recovered.transcriptionStatus, 'running');
      expect(recovered.transcriptionAttempt, 3);
      expect(recovered.transcriptionRequestId, 'request-$statusCode');
      expect(recovered.transcriptionJobId, 'job-$statusCode');
      expect(
        recovered.transcriptionError,
        startsWith('reconciliation_pending:'),
      );
      expect(
        await storage.pathFor('auth-$statusCode').readAsBytes(),
        [1, 2, 3],
      );
    }
    expect(fake.enqueueCalls, 0);
  });

  test('stores one row connection error and continues reconciling other rows',
      () async {
    await seedRow(
      row(
        id: 'r1',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-1',
        transcriptionJobId: 'job-1',
        transcriptionAttempt: 1,
      ),
    );
    await seedRow(
      row(
        id: 'r2',
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-2',
        transcriptionJobId: 'job-2',
        transcriptionAttempt: 1,
      ),
    );
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (jobId) {
        if (jobId == 'job-1') {
          throw const SocketException('server unavailable');
        }
        return const TranscriptionJobSnapshot(
          id: 'job-2',
          requestId: 'request-2',
          dumpId: 'r2',
          status: 'completed',
          model: 'large-v3',
          transcript: 'row two recovered',
        );
      },
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final first = (await db.getDump('r1'))!;
    final second = (await db.getDump('r2'))!;
    expect(first.transcriptionStatus, 'running');
    expect(first.transcriptionRequestId, 'request-1');
    expect(first.transcriptionJobId, 'job-1');
    expect(first.transcriptionError, startsWith('reconciliation_pending:'));
    expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    expect(second.transcriptionStatus, 'completed');
    expect(second.transcript, 'row two recovered');
  });

  test('lost enqueue response keeps one recoverable request identity',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must recover later',
      enqueueError: TimeoutException('response lost'),
    );
    var generatedIds = 0;
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++generatedIds}',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');
    final afterLostResponse = (await db.getDump('r1'))!;
    await service.transcribeDump('r1');
    final afterSecondTap = (await db.getDump('r1'))!;

    expect(afterLostResponse.transcriptionStatus, 'uploading');
    expect(afterLostResponse.transcriptionRequestId, 'request-1');
    expect(afterLostResponse.transcriptionAttempt, 1);
    expect(
      afterLostResponse.transcriptionError,
      startsWith('enqueue_pending:'),
    );
    expect(afterSecondTap.transcriptionRequestId, 'request-1');
    expect(afterSecondTap.transcriptionAttempt, 1);
    expect(generatedIds, 1);
    expect(fake.enqueueCalls, 1);
    expect(storage.pathFor('r1').existsSync(), isTrue);
  });

  final enqueueRequestOptions = RequestOptions(path: '/v1/dumps/r1/transcribe');
  for (final failure in <(String, Object)>[
    for (final status in [408, 429, 503, 418])
      (
        'api_$status',
        ApiException(
          statusCode: status,
          code: 'http_error',
          message: 'HTTP $status after commit',
        ),
      ),
    for (final status in [408, 429, 503, 418])
      (
        'dio_bad_response_$status',
        DioException(
          requestOptions: enqueueRequestOptions,
          response: Response<Map<String, dynamic>>(
            requestOptions: enqueueRequestOptions,
            statusCode: status,
            data: const {
              'error': {
                'code': 'http_error',
                'message': 'uncertain response',
              },
            },
          ),
          type: DioExceptionType.badResponse,
        ),
      ),
  ]) {
    test(
        'committed enqueue ${failure.$1} stays recoverable and recovery reuses its request ID',
        () async {
      await seedRow(row());
      final committedJobs = <String, TranscriptionJobSnapshot>{};
      var loseFirstResponse = true;
      final fake = _FakeTranscriptionClient(
        completedTranscript: 'recover later',
        onEnqueue: (dumpId, requestId, model) {
          final committed = committedJobs.putIfAbsent(
            requestId,
            () => TranscriptionJobSnapshot(
              id: 'committed-job-${committedJobs.length + 1}',
              requestId: requestId,
              dumpId: dumpId,
              status: 'queued',
              model: model,
            ),
          );
          if (loseFirstResponse) {
            loseFirstResponse = false;
            throw failure.$2;
          }
          return committed;
        },
      );
      var generatedIds = 0;
      final service = ServerTranscriptionService(
        client: fake,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-${++generatedIds}',
      );
      addTearDown(service.dispose);

      await service.transcribeDump('r1');
      final afterLostResponse = (await db.getDump('r1'))!;
      final recoverable = (await db.dumpsNeedingTranscriptionRecovery())
          .singleWhere((candidate) => candidate.id == 'r1');
      final recoveredJob = await fake.enqueueTranscription(
        recoverable.id,
        requestId: recoverable.transcriptionRequestId!,
      );

      expect(afterLostResponse.transcriptionStatus, 'uploading');
      expect(afterLostResponse.transcriptionAttempt, 1);
      expect(afterLostResponse.transcriptionRequestId, 'request-1');
      expect(afterLostResponse.transcriptionJobId, isNull);
      expect(
        afterLostResponse.transcriptionError,
        startsWith('enqueue_pending:'),
      );
      expect(fake.enqueueRequestIds, ['request-1', 'request-1']);
      expect(recoveredJob.id, 'committed-job-1');
      expect(committedJobs, hasLength(1));
      expect(generatedIds, 1);
      expect(storage.pathFor('r1').existsSync(), isTrue);
    });
  }

  test('post-enqueue timeout retains the same recoverable job identity',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must recover later',
      streamEvents: const [
        JobEvent('queued', {}),
        JobEvent('running', {}),
        JobEvent('timeout', {'message': 'deadline exhausted'}),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-stream-timeout',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'running');
    expect(saved.transcriptionRequestId, 'request-stream-timeout');
    expect(saved.transcriptionJobId, 'job-r1');
    expect(saved.transcriptionAttempt, 1);
    expect(saved.transcriptionError, startsWith('reconciliation_pending:'));
  });

  test('ordinary recoverable local exit starts one recovery scan', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      streamEvents: const [
        JobEvent('queued', {}),
        JobEvent('running', {}),
        JobEvent('timeout', {'message': 'deadline exhausted'}),
      ],
      onGetJob: (jobId) => const TranscriptionJobSnapshot(
        id: 'job-r1',
        requestId: 'request-auto-recovery',
        dumpId: 'r1',
        status: 'completed',
        model: 'large-v3',
        transcript: 'automatically recovered',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-auto-recovery',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final deadline = DateTime.now().add(const Duration(milliseconds: 200));
    late DumpRow saved;
    while (true) {
      saved = (await db.getDump('r1'))!;
      if (saved.transcriptionStatus == 'completed' &&
          saved.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('ordinary recoverable local exit was not reconciled');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(fake.getJobIds, ['job-r1']);
    expect(fake.enqueueCalls, 1);
    expect(saved.transcriptionAttempt, 1);
    expect(saved.transcriptionRequestId, 'request-auto-recovery');
    expect(saved.transcriptionJobId, 'job-r1');
    expect(saved.transcript, 'automatically recovered');
  });

  for (final stalledPhase in ['metadata', 'audio', 'enqueue']) {
    test('$stalledPhase request deadline releases the local FIFO', () async {
      await seedRow(row(id: 'r1'));
      await seedRow(row(id: 'r2'));
      final never = Completer<void>();
      var createHookCalls = 0;
      var uploadHookCalls = 0;
      final fake = _FakeTranscriptionClient(
        completedTranscript: 'completed after bounded predecessor',
        onCreate: () async {
          createHookCalls += 1;
          if (stalledPhase == 'metadata' && createHookCalls == 1) {
            await never.future;
          }
        },
        onUpload: () async {
          uploadHookCalls += 1;
          if (stalledPhase == 'audio' && uploadHookCalls == 1) {
            await never.future;
          }
        },
        onEnqueue: (dumpId, requestId, model) async {
          if (stalledPhase == 'enqueue' && dumpId == 'r1') {
            await never.future;
          }
          return TranscriptionJobSnapshot(
            id: 'job-$dumpId',
            requestId: requestId,
            dumpId: dumpId,
            status: 'queued',
            model: model,
          );
        },
      );
      var nextRequest = 0;
      final service = ServerTranscriptionService(
        client: fake,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-${++nextRequest}',
        operationRequestTimeout: const Duration(milliseconds: 10),
        recoveryRequestTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      final first = service.transcribeDump('r1');
      final second = service.transcribeDump('r2');
      await second.timeout(const Duration(milliseconds: 300));
      await first.timeout(const Duration(milliseconds: 300));

      service.dispose();
      never.complete();
      await mutations.drain();

      final firstRow = (await db.getDump('r1'))!;
      final secondRow = (await db.getDump('r2'))!;
      expect(firstRow.transcriptionAttempt, 1);
      expect(firstRow.transcriptionRequestId, 'request-1');
      expect(secondRow.transcriptionStatus, 'completed');
      expect(secondRow.transcriptionAttempt, 1);
      expect(secondRow.transcriptionRequestId, 'request-2');
      expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
      expect(await storage.pathFor('r2').readAsBytes(), [1, 2, 3]);
    });
  }

  test('post-enqueue socket failure retains the recoverable job identity',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must recover later',
      streamEvents: const [
        JobEvent('queued', {}),
        JobEvent('running', {}),
      ],
      streamError: const SocketException('connection lost'),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-stream-socket',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'running');
    expect(saved.transcriptionRequestId, 'request-stream-socket');
    expect(saved.transcriptionJobId, 'job-r1');
    expect(saved.transcriptionAttempt, 1);
    expect(saved.transcriptionError, startsWith('reconciliation_pending:'));
  });

  final requestOptions = RequestOptions(path: '/v1/jobs/job-r1/events');
  for (final failure in <(String, Object)>[
    ('format', const FormatException('malformed SSE payload')),
    ('http', const HttpException('transport closed')),
    ('handshake', HandshakeException('TLS session lost')),
    (
      'dio_receive_timeout_with_response',
      DioException(
        requestOptions: requestOptions,
        response:
            Response<void>(requestOptions: requestOptions, statusCode: 200),
        type: DioExceptionType.receiveTimeout,
      ),
    ),
  ]) {
    test('post-enqueue ${failure.$1} failure retains the job identity',
        () async {
      await seedRow(row());
      final requestId = 'request-stream-${failure.$1}';
      final fake = _FakeTranscriptionClient(
        completedTranscript: 'must recover later',
        streamEvents: const [
          JobEvent('queued', {}),
          JobEvent('running', {}),
        ],
        streamError: failure.$2,
      );
      final service = ServerTranscriptionService(
        client: fake,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => requestId,
      );
      addTearDown(service.dispose);

      await service.transcribeDump('r1');

      final saved = (await db.getDump('r1'))!;
      expect(saved.transcriptionStatus, 'running');
      expect(saved.transcriptionRequestId, requestId);
      expect(saved.transcriptionJobId, 'job-r1');
      expect(saved.transcriptionAttempt, 1);
      expect(saved.transcriptionError, startsWith('reconciliation_pending:'));
    });
  }

  for (final statusCode in [401, 403]) {
    test('post-enqueue $statusCode preserves the current job identity',
        () async {
      await seedRow(row());
      final fake = _FakeTranscriptionClient(
        completedTranscript: 'unused',
        streamEvents: const [
          JobEvent('queued', {}),
          JobEvent('running', {}),
        ],
        streamError: ApiException(
          statusCode: statusCode,
          code: 'http_error',
          message: 'credentials rejected',
        ),
      );
      final service = ServerTranscriptionService(
        client: fake,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-auth-$statusCode',
      );
      addTearDown(service.dispose);

      await service.transcribeDump('r1');
      service.dispose();

      final saved = (await db.getDump('r1'))!;
      expect(saved.transcriptionStatus, 'running');
      expect(saved.transcriptionAttempt, 1);
      expect(saved.transcriptionRequestId, 'request-auth-$statusCode');
      expect(saved.transcriptionJobId, 'job-r1');
      expect(saved.transcriptionError, startsWith('reconciliation_pending:'));
      expect(await storage.pathFor('r1').readAsBytes(), [1, 2, 3]);
    });
  }

  test('cross-instance start race enqueues exactly one attempt', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(completedTranscript: 'only once');
    var nextId = 0;
    final first = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++nextId}',
    );
    final second = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-${++nextId}',
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await Future.wait([
      first.transcribeDump('r1'),
      second.transcribeDump('r1'),
    ]);

    final saved = (await db.getDump('r1'))!;
    expect(fake.enqueueCalls, 1);
    expect(saved.transcriptionAttempt, 1);
    expect(saved.transcriptionStatus, 'completed');
  });

  test('database failures cannot strand the queue or terminalize completion',
      () async {
    await db.close();
    db = _ThrowingCompletionDb();
    await seedRow(row());
    final fake = _FakeTranscriptionClient(completedTranscript: 'server done');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-db-error',
    );
    addTearDown(service.dispose);

    await service
        .transcribeDump('r1')
        .timeout(const Duration(milliseconds: 500));

    final throwingDb = db as _ThrowingCompletionDb;
    throwingDb.failTerminalPersistence = false;
    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'running');
    expect(saved.transcriptionRequestId, 'request-db-error');
    expect(saved.transcriptionJobId, 'job-r1');
  });

  test('definitive enqueue conflict becomes durable failed state', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must not complete',
      enqueueError: const ApiException(
        statusCode: 409,
        code: 'request_id_conflict',
        message: 'request ID already belongs to another dump',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-conflict',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'failed');
    expect(saved.transcriptionRequestId, 'request-conflict');
    expect(saved.transcriptionError, contains('request_id_conflict'));
    expect(storage.pathFor('r1').existsSync(), isTrue);
  });

  test('terminal server failure keeps its job identity and raw audio',
      () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'must not complete',
      streamEvents: const [
        JobEvent('queued', {}),
        JobEvent('running', {}),
        JobEvent('failed', {'error': 'worker crashed'}),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-server-failed',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'failed');
    expect(saved.transcriptionRequestId, 'request-server-failed');
    expect(saved.transcriptionJobId, 'job-r1');
    expect(saved.transcriptionError, contains('worker crashed'));
    expect(storage.pathFor('r1').existsSync(), isTrue);
  });

  test('empty completed transcript stores the exact durable error', () async {
    await seedRow(row());
    final fake = _FakeTranscriptionClient(completedTranscript: '   ');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-empty',
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = (await db.getDump('r1'))!;
    expect(saved.transcriptionStatus, 'failed');
    expect(
      saved.transcriptionError,
      contains('Server returned an empty transcript'),
    );
    expect(storage.pathFor('r1').existsSync(), isTrue);
  });

  test('uploads then enqueues then persists the SSE transcript', () async {
    await seedRow(row());
    final fake =
        _FakeTranscriptionClient(completedTranscript: 'phone transcript');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('r1');

    final saved = await db.getDump('r1');
    final sidecar = jsonDecode(storage.metaPathFor('r1').readAsStringSync())
        as Map<String, dynamic>;
    expect(saved!.transcript, 'phone transcript');
    expect(sidecar['transcript'], 'phone transcript');
    expect(sidecar['transcriptionStatus'], 'completed');
    expect(sidecar['transcriptionError'], isNull);
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
  });

  test('duplicate transcribe taps return the same future', () async {
    await seedRow(row());
    final fake =
        _FakeTranscriptionClient(completedTranscript: 'dup transcript');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    final a = service.transcribeDump('r1');
    final b = service.transcribeDump('r1');
    expect(identical(a, b), isTrue);

    await a;
    expect(fake.createCalls, 1);
    expect(fake.uploadCalls, 1);
    expect(fake.enqueueCalls, 1);
  });

  test('createDump failure persists the durable error', () async {
    await seedRow(row(id: 'err-1'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'never seen',
      shouldFailCreate: true,
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('err-1');

    final saved = (await db.getDump('err-1'))!;
    expect(saved.transcriptionStatus, 'failed');
    expect(saved.transcriptionRequestId, isNotNull);
    expect(saved.transcriptionAttempt, 1);
    expect(saved.transcriptionError, contains('create failed'));
    expect(storage.pathFor('err-1').existsSync(), isTrue);
  });

  test('meeting transcripts run through the secretary notes processor',
      () async {
    await seedRow(row(id: 'meet-1', mode: 'meeting'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'Alice will send the notes by Friday.',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('meet-1');

    final saved = await db.getDump('meet-1');
    expect(saved!.transcript, 'Alice will send the notes by Friday.');
    expect(saved.meetingNotes, isNotNull);
    expect(saved.meetingNotes, contains('Action Items'));
  });

  for (final recovered in [false, true]) {
    test(
        'fix round notes regenerated in flight survive ${recovered ? "recovered" : "normal"} completion',
        () async {
      final original = row(
        id: 'notes-in-flight',
        mode: 'meeting',
        transcriptionStatus: recovered ? 'running' : 'completed',
        transcriptionAttempt: 1,
        transcriptionRequestId: 'request-notes-old',
        transcriptionJobId: recovered ? 'job-notes' : null,
      ).copyWith(
        transcript: const Value('Original transcript'),
        meetingNotes: const Value('old notes'),
      );
      await seedRow(original);
      Future<void> regenerate() async {
        final current = (await db.getDump(original.id))!;
        await db.updateDumpMeetingNotes(
          original.id,
          storageKey: fileFixtureKey(original.id),
          expectedTitle: current.title,
          expectedTranscript: current.transcript!,
          expectedTranscriptionAttempt: current.transcriptionAttempt,
          expectedTranscriptionRequestId: current.transcriptionRequestId,
          meetingNotes: 'newly regenerated notes',
          now: DateTime.now(),
        );
      }

      final fake = _FakeTranscriptionClient(
        completedTranscript: 'Replacement transcript',
        onStreamStart: regenerate,
        onGetJob: (_) async {
          await regenerate();
          return const TranscriptionJobSnapshot(
            id: 'job-notes',
            requestId: 'request-notes-old',
            dumpId: 'notes-in-flight',
            status: 'completed',
            model: 'large-v3',
            transcript: 'Replacement transcript',
          );
        },
      );
      final service = ServerTranscriptionService(
        client: fake,
        db: db,
        recordingAccess: access,
        mutations: mutations,
        requestIdFactory: () => 'request-notes-new',
      );
      addTearDown(service.dispose);
      if (recovered) {
        await service.reconcilePending();
      } else {
        await service.transcribeDump(original.id);
      }
      final saved = (await db.getDump(original.id))!;
      expect(saved.transcript, 'Replacement transcript');
      expect(saved.meetingNotes, 'newly regenerated notes');
      final metadata =
          jsonDecode(await storage.metaPathFor(original.id).readAsString())
              as Map;
      expect(metadata['meetingNotes'], 'newly regenerated notes');
      expect(await storage.readBytes(original.id), [1, 2, 3]);
    });
  }

  test(
      'fix round FIFO acceptance is durable before activation and provider recreation',
      () async {
    await seedRow(row(id: 'fifo-first'));
    await seedRow(row(id: 'fifo-second'));
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final firstClient = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onCreate: () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      },
    );
    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(db),
        audioStorageProvider.overrideWithValue(storage),
        recordingAccessProvider.overrideWithValue(access),
        recordingMutationsProvider.overrideWithValue(mutations),
        transcriptionClientProvider.overrideWith((_) => firstClient),
      ],
    );
    addTearDown(() {
      container.dispose();
      if (!release.isCompleted) release.complete();
    });
    container.read(transcriptionRecoveryOwnerProvider);
    final first = container.read(serverTranscriptionServiceProvider);
    await first.reconcilePending();
    final firstWork = first.transcribeDump('fifo-first');
    await entered.future;
    final secondWork = first.transcribeDump('fifo-second');
    expect(identical(secondWork, first.transcribeDump('fifo-second')), isTrue);
    final accepted = await db
        .watchDump('fifo-second')
        .firstWhere((r) => r?.transcriptionStatus == 'uploading')
        .timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => row(id: 'fifo-second'),
        );
    expect(accepted!.transcriptionStatus, 'uploading');
    expect(accepted.transcriptionRequestId, isNotNull);
    expect(accepted.transcriptionAttempt, 1);
    expect(firstClient.createCalls, 1);
    expect(firstClient.enqueueCalls, 0);
    final replacementClient = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (id, request, model) => TranscriptionJobSnapshot(
        id: 'job-$id',
        requestId: request,
        dumpId: id,
        model: model,
        status: 'completed',
        transcript: 'Recovered $id',
      ),
    );
    container.read(transcriptionClientProvider.notifier).state =
        replacementClient;
    final replacement = container.read(serverTranscriptionServiceProvider);
    await replacement.reconcilePending();
    await firstWork;
    await secondWork;
    final saved = (await db.getDump('fifo-second'))!;
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcriptionRequestId, accepted.transcriptionRequestId);
    expect(saved.transcriptionAttempt, 1);
    expect(
      replacementClient.enqueueRequestIds
          .where((id) => id == accepted.transcriptionRequestId),
      hasLength(1),
    );
    expect(await storage.readBytes('fifo-second'), [1, 2, 3]);
  });

  test('fix round disposal waits for pending durable acceptance', () async {
    await db.close();
    final paused = _PausedOwnershipDb();
    db = paused;
    await seedRow(row());
    final fake = _FakeTranscriptionClient(completedTranscript: 'unused');
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-before-disposal',
    );
    addTearDown(() {
      service.dispose();
      if (!paused.release.isCompleted) paused.release.complete();
    });
    var finished = false;
    final work = service.transcribeDump('r1').then((_) {
      finished = true;
    });
    await paused.entered.future;
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    paused.release.complete();
    await work;
    final accepted = (await db.getDump('r1'))!;
    expect(accepted.transcriptionStatus, 'uploading');
    expect(accepted.transcriptionRequestId, 'request-before-disposal');
    expect(fake.createCalls, 0);
    expect(fake.enqueueCalls, 0);
  });

  test(
      'round 2 durable signals coalesce and retain backoff across unrelated work and scope replacement',
      () async {
    await db.close();
    final observed = _ObservedRecoveryDb();
    db = observed;
    await seedRow(
      row().copyWith(
        transcriptionStatus: 'uploading',
        transcriptionAttempt: 1,
        transcriptionRequestId: const Value('durable-request'),
      ),
    );
    await seedRow(
      row(id: 'r2').copyWith(
        transcriptionStatus: 'completed',
        transcript: const Value('Before'),
      ),
    );
    final failing = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (_, __, ___) => throw const ApiException(
        statusCode: 503,
        code: 'unavailable',
        message: 'offline',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(db),
        audioStorageProvider.overrideWithValue(storage),
        recordingAccessProvider.overrideWithValue(access),
        recordingMutationsProvider.overrideWithValue(mutations),
        transcriptionClientProvider.overrideWith((_) => failing),
      ],
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) container.dispose();
    });
    await container.read(serverTranscriptionServiceProvider).reconcilePending();
    await _eventually(
      () => failing.enqueueCalls == 2,
      'bootstrap plus immediate retry',
    );
    container.read(transcriptionRecoveryOwnerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final scansBefore = observed.scans;
    final deliveriesBefore = observed.deliveries;
    for (var i = 0; i < 20; i++) {
      await db.updateTranscriptionStatus(
        'r1',
        storageKey: fileFixtureKey('r1'),
        attempt: 1,
        requestId: 'durable-request',
        status: TranscriptionStatus.uploading,
        error: 'reconciliation_pending: probe $i',
        now: DateTime.now(),
      );
    }
    await _eventually(
      () => observed.deliveries > deliveriesBefore,
      'real SQLite notifications delivered',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      observed.scans,
      scansBefore,
      reason: 'same-work writes must not trigger scans',
    );
    expect(failing.enqueueCalls, 2);
    // A different row needs immediate sidecar repair while r1 is in backoff.
    await db.updateDumpTranscript(
      'r2',
      storageKey: fileFixtureKey('r2'),
      expectedTranscript: 'Before',
      expectedTranscriptionAttempt: 0,
      expectedTranscriptionRequestId: null,
      transcript: 'After',
      now: DateTime.now(),
    );
    await _eventually(
      () async => (await db.getDump('r2'))!.transcriptionError == null,
      'unrelated repair',
    );
    expect(
      failing.enqueueCalls,
      2,
      reason: 'unrelated work cannot accelerate a pending retry',
    );
    expect(failing.enqueueRequestIds.toSet(), {'durable-request'});

    final recovered = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onEnqueue: (id, request, model) => TranscriptionJobSnapshot(
        id: 'job-replacement',
        requestId: request,
        dumpId: id,
        model: model,
        status: 'completed',
        transcript: 'Recovered',
      ),
    );
    container.read(transcriptionClientProvider.notifier).state = recovered;
    await container.read(serverTranscriptionServiceProvider).reconcilePending();
    expect(recovered.enqueueRequestIds, ['durable-request']);
    final idleClients = <_FakeTranscriptionClient>[];
    for (var i = 0; i < 4; i++) {
      final idle =
          _FakeTranscriptionClient(completedTranscript: 'must not run');
      idleClients.add(idle);
      container.read(transcriptionClientProvider.notifier).state = idle;
      await container
          .read(serverTranscriptionServiceProvider)
          .reconcilePending();
    }
    expect(observed.subscriptions, 1);
    expect(observed.activeSubscriptions, 1);
    final finalScans = observed.scans;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      observed.scans,
      finalScans,
      reason: 'settled work cannot self-trigger',
    );
    container.dispose();
    disposed = true;
    await _eventually(
      () => observed.activeSubscriptions == 0,
      'subscription cancelled on scope disposal',
    );
    await db.beginTranscriptionAttempt(
      'r1',
      storageKey: fileFixtureKey('r1'),
      requestId: 'after-scope-shutdown',
      now: DateTime.now(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(observed.scans, finalScans);
    expect(failing.enqueueCalls, 2, reason: 'disposed retry timer cannot fire');
    expect(recovered.enqueueCalls, 1);
    expect(idleClients.every((c) => c.calls.isEmpty), isTrue);
    expect(await storage.readBytes('r1'), [1, 2, 3]);
    expect(await storage.readBytes('r2'), [1, 2, 3]);
  });

  for (final phase in ['begin attempt', 'row read', 'accepted DB return']) {
    for (final eagerRead in [true, false]) {
      test(
          'round 2 late acceptance after replacement empty scan $phase consumer-read=$eagerRead',
          () async {
        await db.close();
        final paused = _LateAcceptanceDb(
          phase == 'row read',
          pauseAfterCommit: phase == 'accepted DB return',
          holdReplacementQuery: phase != 'accepted DB return',
        );
        db = paused;
        await seedRow(row());
        final oldClient =
            _FakeTranscriptionClient(completedTranscript: 'old must not run');
        final newClient = _FakeTranscriptionClient(
          completedTranscript: 'unused',
          onEnqueue: (id, request, model) => TranscriptionJobSnapshot(
            id: 'recovered-job',
            requestId: request,
            dumpId: id,
            model: model,
            status: 'completed',
            transcript: 'Recovered late acceptance',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            localDbProvider.overrideWithValue(db),
            audioStorageProvider.overrideWithValue(storage),
            recordingAccessProvider.overrideWithValue(access),
            recordingMutationsProvider.overrideWithValue(mutations),
            transcriptionClientProvider.overrideWith((_) => oldClient),
          ],
          observers: [_LateAcceptanceObserver(paused)],
        );
        addTearDown(() {
          container.dispose();
          if (!paused.releaseReplacementQuery.isCompleted) {
            paused.releaseReplacementQuery.complete();
          }
          if (!paused.release.isCompleted) paused.release.complete();
        });
        final oldService = container.read(serverTranscriptionServiceProvider);
        await oldService.reconcilePending();
        container.read(transcriptionRecoveryOwnerProvider);
        paused.armed = true;
        final work = oldService.transcribeDump('r1');
        addTearDown(() async {
          if (!paused.releaseReplacementQuery.isCompleted) {
            paused.releaseReplacementQuery.complete();
          }
          if (!paused.release.isCompleted) paused.release.complete();
          await work.catchError((_) {});
          await mutations.drain();
        });
        await paused.entered.future;
        if (phase == 'row read') {
          expect(paused.admissionReadObserved, isTrue);
          expect(paused.allocations, 0);
        }
        if (phase == 'accepted DB return') {
          final committed = (await db.getDump('r1'))!;
          expect(committed.transcriptionRequestId, paused.allocatedRequest);
          expect(committed.transcriptionAttempt, 1);
          expect(committed.transcriptionStatus, 'uploading');
        }
        final scansBeforeReplacement = paused.scans;
        final replacementDeadline =
            DateTime.now().add(const Duration(seconds: 3));
        container.read(transcriptionClientProvider.notifier).state = newClient;
        Future<void>? replacementScan;
        if (eagerRead) {
          final replacement =
              container.read(serverTranscriptionServiceProvider);
          expect(identical(oldService, replacement), isFalse);
          replacementScan = replacement.reconcilePending();
        } else if (phase == 'accepted DB return') {
          await _eventually(
            () => paused.scans > scansBeforeReplacement,
            'app owner must resolve lazy replacement without a consumer read',
          );
        }
        if (phase != 'accepted DB return') {
          await paused.replacementQueryEntered.future.timeout(
            replacementDeadline.difference(DateTime.now()),
          );
          expect(paused.firstService, same(oldService));
          expect(paused.queryService, same(paused.currentService));
          expect(paused.queryService, isNot(same(oldService)));
          expect(paused.release.isCompleted, isFalse);
          expect(
            paused.replacementQueryCompleted.isCompleted,
            isFalse,
            reason: 'entered but held real query cannot satisfy completion',
          );
          paused.releaseReplacementQuery.complete();
          final replacementRows =
              await paused.replacementQueryCompleted.future.timeout(
            replacementDeadline.difference(DateTime.now()),
          );
          expect(replacementRows, isEmpty);
          if (replacementScan != null) {
            await replacementScan.timeout(
              replacementDeadline.difference(DateTime.now()),
            );
          }
          expect(paused.release.isCompleted, isFalse);
        }
        // The accepted-return phase already committed uploading; it retains
        // admission/held-return evidence, not an impossible empty-scan demand.
        final blockedDeletion = await mutations.acquire(
          'r1',
          UseKind.deletion,
          expectedIncarnation: fileFixtureKey('r1').incarnation,
        );
        expect(blockedDeletion, isA<Fail<UseLease>>());
        if (!paused.release.isCompleted) paused.release.complete();
        await work;
        await replacementScan;
        final deadline = DateTime.now().add(const Duration(seconds: 1));
        late DumpRow saved;
        do {
          saved = (await db.getDump('r1'))!;
          if (saved.transcriptionStatus == 'completed' &&
              saved.transcriptionError == null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        } while (DateTime.now().isBefore(deadline));
        expect(
          saved.transcriptionStatus,
          'completed',
          reason: 'no explicit rescue scan or lifecycle event',
        );
        expect(saved.transcriptionRequestId, paused.allocatedRequest);
        expect(saved.transcriptionAttempt, 1);
        expect(paused.allocations, 1);
        expect(oldClient.calls, isEmpty);
        expect(newClient.enqueueRequestIds, [paused.allocatedRequest]);
        expect(newClient.createCalls, 0);
        expect(await storage.readBytes('r1'), [1, 2, 3]);
      });
    }
  }

  test('meeting retranscription preserves existing notes until regeneration',
      () async {
    final original = row(
      id: 'meet-retry',
      mode: 'meeting',
      transcriptionStatus: 'completed',
      transcriptionRequestId: 'request-old',
      transcriptionJobId: 'job-old',
      transcriptionAttempt: 2,
      transcriptionCompletedAt: DateTime.utc(2026, 9, 14, 20),
    ).copyWith(
      transcript: const Value('Original meeting transcript.'),
      meetingNotes: const Value('Reviewed notes that must stay unchanged.'),
    );
    await seedRow(original);
    await storage.writeMetadata(original.id, dumpMetadata(original));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'Alice will replace the agenda by Friday.',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-retry',
    );
    addTearDown(service.dispose);

    await service.transcribeDump(original.id);

    final saved = (await db.getDump(original.id))!;
    final sidecar = jsonDecode(
      await storage.metaPathFor(original.id).readAsString(),
    ) as Map<String, dynamic>;
    expect(saved.transcript, 'Alice will replace the agenda by Friday.');
    expect(saved.meetingNotes, 'Reviewed notes that must stay unchanged.');
    expect(sidecar['transcript'], 'Alice will replace the agenda by Friday.');
    expect(
      sidecar['meetingNotes'],
      'Reviewed notes that must stay unchanged.',
    );
  });

  test('recovered meeting retranscription preserves existing notes', () async {
    final pending = row(
      id: 'meet-recovery',
      mode: 'meeting',
      transcriptionStatus: 'running',
      transcriptionRequestId: 'request-recovery',
      transcriptionJobId: 'job-recovery',
      transcriptionAttempt: 3,
    ).copyWith(
      transcript: const Value('Original recovered transcript.'),
      meetingNotes: const Value('Reviewed recovery notes.'),
    );
    await seedRow(pending);
    await storage.writeMetadata(pending.id, dumpMetadata(pending));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (_) => const TranscriptionJobSnapshot(
        id: 'job-recovery',
        requestId: 'request-recovery',
        dumpId: 'meet-recovery',
        status: 'completed',
        model: 'large-v3',
        transcript: 'Recovered replacement transcript.',
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final saved = (await db.getDump(pending.id))!;
    final sidecar = jsonDecode(
      await storage.metaPathFor(pending.id).readAsString(),
    ) as Map<String, dynamic>;
    expect(saved.transcript, 'Recovered replacement transcript.');
    expect(saved.meetingNotes, 'Reviewed recovery notes.');
    expect(sidecar['transcript'], 'Recovered replacement transcript.');
    expect(sidecar['meetingNotes'], 'Reviewed recovery notes.');
  });

  test('only one same-attempt completion callback owns a delayed sidecar',
      () async {
    await seedRow(row(id: 'duplicate-completion'));
    final attempt = await db.beginTranscriptionAttempt(
      'duplicate-completion',
      storageKey: fileFixtureKey('duplicate-completion'),
      requestId: 'request-duplicate-completion',
      now: DateTime.utc(2026, 9, 14, 23),
    );
    await db.updateTranscriptionStatus(
      attempt.id,
      storageKey: fileFixtureKey(attempt.id),
      attempt: attempt.transcriptionAttempt,
      requestId: attempt.transcriptionRequestId!,
      status: TranscriptionStatus.running,
      jobId: 'job-duplicate-completion',
      now: DateTime.utc(2026, 9, 14, 23, 0, 1),
    );
    final writerStarted = Completer<void>();
    final releaseWriter = Completer<void>();
    addTearDown(() {
      if (!releaseWriter.isCompleted) releaseWriter.complete();
    });
    var sidecarWrites = 0;

    Future<bool> complete(String transcript, {required bool delay}) async {
      final won = await db.completeTranscriptionAttempt(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        transcript: transcript,
        now: DateTime.utc(2026, 9, 14, 23, 0, 2),
        sidecarError: 'sidecar_sync_pending: write pending',
      );
      if (!won) return false;
      await storage.runSerializedMetadataWrite<void>(attempt.id, (write) async {
        final current = (await db.getDump(attempt.id))!;
        sidecarWrites += 1;
        if (delay) {
          writerStarted.complete();
          await releaseWriter.future;
        }
        await write(dumpMetadata(current));
        final cleared = await db.updateTranscriptionSidecarError(
          attempt.id,
          storageKey: fileFixtureKey(attempt.id),
          attempt: attempt.transcriptionAttempt,
          requestId: attempt.transcriptionRequestId!,
          error: null,
          now: DateTime.utc(2026, 9, 14, 23, 0, 3),
        );
        expect(cleared, isTrue);
      });
      return true;
    }

    final winner = complete('winning transcript', delay: true);
    await writerStarted.future;
    final duplicate = await complete('duplicate transcript', delay: false);
    expect(duplicate, isFalse);
    await expectLater(
      db.beginTranscriptionAttempt(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        requestId: 'request-too-early',
        now: DateTime.utc(2026, 9, 14, 23, 0, 4),
      ),
      throwsA(isA<StateError>()),
    );

    releaseWriter.complete();
    expect(await winner, isTrue);
    final next = await db.beginTranscriptionAttempt(
      attempt.id,
      storageKey: fileFixtureKey(attempt.id),
      requestId: 'request-after-writer',
      now: DateTime.utc(2026, 9, 14, 23, 0, 5),
    );
    expect(sidecarWrites, 1);
    expect(next.transcriptionAttempt, 2);
    final metadata = jsonDecode(
      await storage.metaPathFor(attempt.id).readAsString(),
    ) as Map<String, dynamic>;
    expect(metadata['transcript'], 'winning transcript');
  });

  test('serialized detail edits preserve a retry completion and sidecar',
      () async {
    await seedRow(
      row(
        id: 'detail-race',
        mode: 'meeting',
        transcriptionStatus: 'failed',
        transcriptionRequestId: 'request-old',
        transcriptionJobId: 'job-old',
        transcriptionAttempt: 3,
        transcriptionError: 'old failure',
      ).copyWith(
        transcript: const Value('old transcript'),
        meetingNotes: const Value('old notes'),
      ),
    );
    final blockerStarted = Completer<void>();
    final releaseBlocker = Completer<void>();
    addTearDown(() {
      if (!releaseBlocker.isCompleted) releaseBlocker.complete();
    });
    final blocker = access.runSerializedMetadataWrite<void>(
      fileFixtureKey('detail-race'),
      (_) async {
        blockerStarted.complete();
        await releaseBlocker.future;
      },
    );
    await blockerStarted.future;

    Future<void> writeLatestSidecar() {
      return access.runSerializedMetadataWrite<void>(
        fileFixtureKey('detail-race'),
        (writer) async {
          final latest = (await db.getDump('detail-race'))!;
          await writer.write(dumpMetadata(latest));
        },
      );
    }

    await db.updateDumpTitle(
      'detail-race',
      storageKey: fileFixtureKey('detail-race'),
      title: 'Edited during retry',
      now: DateTime.utc(2026, 9, 14, 23, 10),
    );
    final titleSidecar = writeLatestSidecar();

    final fake = _FakeTranscriptionClient(
      completedTranscript: 'winning retry transcript',
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
      requestIdFactory: () => 'request-winning-retry',
      now: () => DateTime.utc(2026, 9, 14, 23, 11),
    );
    addTearDown(service.dispose);
    final transcription = service.transcribeDump('detail-race');

    late DumpRow completed;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (true) {
      completed = (await db.getDump('detail-race'))!;
      if (completed.transcriptionStatus == 'completed' &&
          (completed.transcriptionError?.startsWith('sidecar_sync_pending:') ??
              false)) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('retry did not commit completion before sidecar release');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    await db.updateDumpMeetingNotes(
      'detail-race',
      storageKey: fileFixtureKey('detail-race'),
      expectedTitle: completed.title,
      expectedTranscript: 'winning retry transcript',
      expectedTranscriptionAttempt: completed.transcriptionAttempt,
      expectedTranscriptionRequestId: completed.transcriptionRequestId,
      meetingNotes: 'Edited notes during completion',
      now: DateTime.utc(2026, 9, 14, 23, 12),
    );
    final notesSidecar = writeLatestSidecar();

    releaseBlocker.complete();
    await Future.wait<void>([
      blocker,
      titleSidecar,
      transcription,
      notesSidecar,
    ]);

    final saved = (await db.getDump('detail-race'))!;
    expect(saved.title, 'Edited during retry');
    expect(saved.meetingNotes, 'Edited notes during completion');
    expect(saved.transcript, 'winning retry transcript');
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.transcriptionAttempt, 4);
    expect(saved.transcriptionRequestId, 'request-winning-retry');
    expect(saved.transcriptionJobId, 'job-detail-race');
    expect(saved.transcriptionError, isNull);
    expect(await storage.pathFor('detail-race').readAsBytes(), [1, 2, 3]);

    final metadata = jsonDecode(
      await storage.metaPathFor('detail-race').readAsString(),
    ) as Map<String, dynamic>;
    expect(metadata['title'], 'Edited during retry');
    expect(metadata['meetingNotes'], 'Edited notes during completion');
    expect(metadata['transcript'], 'winning retry transcript');
    expect(metadata['transcriptionStatus'], 'completed');
    expect(metadata['transcriptionAttempt'], 4);
    expect(metadata['transcriptionRequestId'], 'request-winning-retry');
    expect(metadata['transcriptionJobId'], 'job-detail-race');
    expect(metadata['transcriptionError'], isNull);
  });

  test('meeting completions store the formatted timestamp transcript',
      () async {
    await seedRow(row(id: 'meet-segments', mode: 'meeting'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      streamEvents: [
        const JobEvent('queued', {}),
        const JobEvent('running', {}),
        JobEvent('completed', {
          'transcript': 'Hello there. Still me. Follow up later.',
          'segments': [
            {
              'start': 0.0,
              'end': 4.2,
              'speaker': 'Speaker 1',
              'text': 'Hello there.',
            },
            {
              'start': 4.2,
              'end': 9.0,
              'speaker': 'Speaker 1',
              'text': 'Still me.',
            },
            {
              'start': 247.5,
              'end': 251.0,
              'speaker': 'Speaker 2',
              'text': 'Follow up later.',
            },
          ],
        }),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('meet-segments');

    final saved = (await db.getDump('meet-segments'))!;
    expect(
      saved.transcript,
      '00:00:00 Speaker 1\n'
      'Hello there. Still me.\n'
      '\n'
      '00:04:07 Speaker 2\n'
      'Follow up later.',
    );
    expect(saved.transcriptionStatus, 'completed');
    expect(saved.meetingNotes, isNotNull);
    final metadata = jsonDecode(
      await storage.metaPathFor('meet-segments').readAsString(),
    ) as Map<String, dynamic>;
    expect(metadata['transcript'], saved.transcript);
  });

  test('meeting completions with null speakers use timestamp-only headings',
      () async {
    await seedRow(row(id: 'meet-anon', mode: 'meeting'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      streamEvents: [
        JobEvent('completed', {
          'transcript': 'First part. Second part.',
          'segments': [
            {'start': 0.0, 'end': 3.0, 'speaker': null, 'text': 'First part.'},
            {'start': 61.0, 'end': 64.0, 'text': 'Second part.'},
          ],
        }),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('meet-anon');

    final saved = (await db.getDump('meet-anon'))!;
    expect(
      saved.transcript,
      '00:00:00\n'
      'First part.\n'
      '\n'
      '00:01:01\n'
      'Second part.',
    );
    expect(saved.transcript, isNot(contains('Speaker')));
  });

  test('brain dump completions ignore segments and keep the plain transcript',
      () async {
    await seedRow(row(id: 'dump-segments'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      streamEvents: [
        JobEvent('completed', {
          'transcript': 'Hello there. Follow up later.',
          'segments': [
            {
              'start': 0.0,
              'end': 4.2,
              'speaker': 'Speaker 1',
              'text': 'Hello there.',
            },
            {
              'start': 247.5,
              'end': 251.0,
              'speaker': 'Speaker 2',
              'text': 'Follow up later.',
            },
          ],
        }),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('dump-segments');

    final saved = (await db.getDump('dump-segments'))!;
    expect(saved.transcript, 'Hello there. Follow up later.');
    expect(saved.meetingNotes, isNull);
  });

  test('meeting completions without segments keep the plain transcript',
      () async {
    await seedRow(row(id: 'meet-plain', mode: 'meeting'));
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      streamEvents: [
        const JobEvent('completed', {
          'transcript': 'Alice will send the notes by Friday.',
        }),
      ],
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.transcribeDump('meet-plain');

    final saved = (await db.getDump('meet-plain'))!;
    expect(saved.transcript, 'Alice will send the notes by Friday.');
  });

  test('recovered meeting completions store the formatted transcript',
      () async {
    final pending = row(
      id: 'meet-recovered-segments',
      mode: 'meeting',
      transcriptionStatus: 'running',
      transcriptionRequestId: 'request-recovered-segments',
      transcriptionJobId: 'job-recovered-segments',
      transcriptionAttempt: 2,
    );
    await seedRow(pending);
    final fake = _FakeTranscriptionClient(
      completedTranscript: 'unused',
      onGetJob: (_) => const TranscriptionJobSnapshot(
        id: 'job-recovered-segments',
        requestId: 'request-recovered-segments',
        dumpId: 'meet-recovered-segments',
        status: 'completed',
        model: 'large-v3',
        transcript: 'Recovered one. Recovered two.',
        segments: [
          TranscriptSegment(
            start: 12,
            speaker: 'Speaker 1',
            text: 'Recovered one.',
          ),
          TranscriptSegment(
            start: 3661,
            speaker: 'Speaker 2',
            text: 'Recovered two.',
          ),
        ],
      ),
    );
    final service = ServerTranscriptionService(
      client: fake,
      db: db,
      recordingAccess: access,
      mutations: mutations,
    );
    addTearDown(service.dispose);

    await service.reconcilePending();

    final saved = (await db.getDump('meet-recovered-segments'))!;
    expect(
      saved.transcript,
      '00:00:12 Speaker 1\n'
      'Recovered one.\n'
      '\n'
      '01:01:01 Speaker 2\n'
      'Recovered two.',
    );
  });

}
